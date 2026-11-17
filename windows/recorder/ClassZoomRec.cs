// ClassZoom 화면 녹화 도우미 (classzoom-rec.exe)
//
// ClassZoom 본체(AutoHotkey)는 이 프로그램을 숨겨서 실행하고, "제어 파일"에 rec / pause / stop을
// 써서 조종한다. 이 프로그램은
//   1) 마이크(기본 녹음 장치)와 컴퓨터 소리(기본 재생 장치의 루프백)를 WASAPI로 받아
//   2) 이름 있는 파이프로 FFmpeg에 실시간으로 넘기고
//   3) FFmpeg이 화면(gdigrab)과 소리를 섞어 MP4 조각을 만든다.
// 일시정지할 때마다 조각을 끊고, 끝나면 조각들을 하나의 MP4로 이어 붙인다.
// 진행 상황은 "상태 파일"에 한 줄씩 적는다: recording / paused / saving / done <경로> / error <이유>
//
// 빌드: C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /target:winexe /out:classzoom-rec.exe ClassZoomRec.cs
// (.NET Framework 4는 Windows 10/11에 기본으로 들어 있어 따로 설치할 것이 없다)

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace ClassZoom
{
    // ---------------- WASAPI COM 정의 (필요한 메서드까지만, vtable 순서 그대로) ----------------
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    class MMDeviceEnumeratorCo { }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator
    {
        int EnumAudioEndpoints(int dataFlow, int stateMask, out IntPtr devices);
        int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice endpoint);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice
    {
        int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
    }

    [ComImport, Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioClient
    {
        int Initialize(int shareMode, int streamFlags, long bufferDuration, long periodicity, IntPtr format, IntPtr sessionGuid);
        int GetBufferSize(out uint frames);
        int GetStreamLatency(out long latency);
        int GetCurrentPadding(out uint padding);
        int IsFormatSupported(int shareMode, IntPtr format, out IntPtr closest);
        int GetMixFormat(out IntPtr format);
        int GetDevicePeriod(out long defaultPeriod, out long minimumPeriod);
        int Start();
        int Stop();
        int Reset();
        int SetEventHandle(IntPtr handle);
        int GetService(ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object service);
    }

    [ComImport, Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioCaptureClient
    {
        int GetBuffer(out IntPtr data, out uint frames, out uint flags, out ulong devicePosition, out ulong qpcPosition);
        int ReleaseBuffer(uint frames);
        int GetNextPacketSize(out uint frames);
    }

    // ---------------- 소리 한 갈래 (마이크 또는 컴퓨터 소리) ----------------
    class AudioSource
    {
        public readonly string Name;     // "mic" / "sys"
        public int Rate, Channels;       // FFmpeg에 넘기는 형식 (늘 32비트 실수)
        IAudioClient client;
        IAudioCaptureClient capture;
        bool isFloat; int bits; int blockAlign;
        public NamedPipeServerStream Pipe;
        public string PipeName;
        Thread thread;
        volatile bool running;

        public AudioSource(string name) { Name = name; }

        // loopback = true면 기본 재생 장치에서 나가는 소리(컴퓨터 소리)를 받는다
        public bool Init(bool loopback)
        {
            try
            {
                var en = (IMMDeviceEnumerator)new MMDeviceEnumeratorCo();
                IMMDevice dev;
                if (en.GetDefaultAudioEndpoint(loopback ? 0 : 1, 0, out dev) != 0 || dev == null) return false;
                Guid iidClient = typeof(IAudioClient).GUID;
                object o;
                if (dev.Activate(ref iidClient, 23 /* CLSCTX_ALL */, IntPtr.Zero, out o) != 0) return false;
                client = (IAudioClient)o;
                IntPtr fmt;
                if (client.GetMixFormat(out fmt) != 0) return false;
                int tag = Marshal.ReadInt16(fmt, 0) & 0xFFFF;
                Channels = Marshal.ReadInt16(fmt, 2);
                Rate = Marshal.ReadInt32(fmt, 4);
                blockAlign = Marshal.ReadInt16(fmt, 12);
                bits = Marshal.ReadInt16(fmt, 14);
                isFloat = tag == 3;
                if (tag == 0xFFFE) // WAVE_FORMAT_EXTENSIBLE: SubFormat GUID의 첫 2바이트가 실제 형식
                    isFloat = (Marshal.ReadInt16(fmt, 24) & 0xFFFF) == 3;
                int flags = loopback ? 0x00020000 /* AUDCLNT_STREAMFLAGS_LOOPBACK */ : 0;
                int hr = client.Initialize(0 /* shared */, flags, 10000000 /* 1초 */, 0, fmt, IntPtr.Zero);
                Marshal.FreeCoTaskMem(fmt);
                if (hr != 0) return false;
                Guid iidCap = typeof(IAudioCaptureClient).GUID;
                if (client.GetService(ref iidCap, out o) != 0) return false;
                capture = (IAudioCaptureClient)o;
                return Channels > 0 && Rate > 0;
            }
            catch { return false; }
        }

        public string FfmpegInput()
        {
            return "-thread_queue_size 4096 -f f32le -ar " + Rate + " -ac " + Channels + " -i \\\\.\\pipe\\" + PipeName + " ";
        }

        // 조각 하나를 시작한다: 파이프를 만들고, FFmpeg이 붙으면 소리를 흘려보낸다
        public void BeginSegment(string pipeName)
        {
            PipeName = pipeName;
            Pipe = new NamedPipeServerStream(pipeName, PipeDirection.Out, 1, PipeTransmissionMode.Byte, PipeOptions.None, 0, 1 << 20);
            running = true;
            thread = new Thread(Loop) { IsBackground = true };
            thread.Start();
        }

        public void EndSegment()
        {
            running = false;
            try { Pipe.Dispose(); } catch { }
            if (thread != null) thread.Join(3000);
            try { client.Stop(); client.Reset(); } catch { }
        }

        void Loop()
        {
            try { Pipe.WaitForConnection(); } catch { return; }
            client.Reset();
            client.Start();
            var sw = Stopwatch.StartNew();
            long written = 0;
            byte[] outBuf = new byte[0];
            try
            {
                while (running)
                {
                    uint n;
                    capture.GetNextPacketSize(out n);
                    while (n > 0 && running)
                    {
                        IntPtr data; uint frames, fl; ulong a, b;
                        if (capture.GetBuffer(out data, out frames, out fl, out a, out b) != 0) break;
                        int bytes = (int)frames * Channels * 4;
                        if (outBuf.Length < bytes) outBuf = new byte[bytes];
                        if ((fl & 2) != 0) Array.Clear(outBuf, 0, bytes); // AUDCLNT_BUFFERFLAGS_SILENT
                        else Convert(data, (int)frames, outBuf);
                        capture.ReleaseBuffer(frames);
                        Pipe.Write(outBuf, 0, bytes);
                        written += frames;
                        capture.GetNextPacketSize(out n);
                    }
                    // 컴퓨터에서 아무 소리도 안 나면 루프백은 데이터를 보내지 않는다. 그대로 두면 소리가
                    // 영상보다 짧아져 어긋나므로, 실제 흐른 시간만큼 무음을 채운다 (50ms 여유).
                    long target = (long)(sw.Elapsed.TotalSeconds * Rate) - Rate / 20;
                    if (written < target)
                    {
                        int frames = (int)Math.Min(target - written, Rate);
                        int bytes = frames * Channels * 4;
                        if (outBuf.Length < bytes) outBuf = new byte[bytes];
                        Array.Clear(outBuf, 0, bytes);
                        Pipe.Write(outBuf, 0, bytes);
                        written += frames;
                    }
                    Thread.Sleep(5);
                }
            }
            catch { } // FFmpeg이 파이프를 닫으면 여기로 온다 (조각 끝)
        }

        // 장치 형식 → 32비트 실수 (FFmpeg f32le)
        void Convert(IntPtr src, int frames, byte[] dst)
        {
            int samples = frames * Channels;
            if (isFloat && bits == 32) { Marshal.Copy(src, dst, 0, samples * 4); return; }
            byte[] raw = new byte[frames * blockAlign];
            Marshal.Copy(src, raw, 0, raw.Length);
            int bps = bits / 8;
            for (int i = 0; i < samples; i++)
            {
                float v;
                int o = i * bps;
                if (bps == 2) v = BitConverter.ToInt16(raw, o) / 32768f;
                else if (bps == 3) v = ((raw[o] << 8 | raw[o + 1] << 16 | raw[o + 2] << 24) >> 8) / 8388608f;
                else if (bps == 4) v = BitConverter.ToInt32(raw, o) / 2147483648f;
                else v = 0;
                byte[] f = BitConverter.GetBytes(v);
                Buffer.BlockCopy(f, 0, dst, i * 4, 4);
            }
        }
    }

    // ---------------- 녹화 진행 ----------------
    static class Program
    {
        static Dictionary<string, string> A = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        static string statusPath, controlPath, logPath;

        static string Arg(string k, string d) { string v; return A.TryGetValue(k, out v) ? v : d; }
        static int ArgInt(string k, int d) { int v; return int.TryParse(Arg(k, ""), out v) ? v : d; }

        static void Status(string s)
        {
            try { File.AppendAllText(statusPath, s + "\r\n", new UTF8Encoding(false)); } catch { }
        }

        static void Log(string s)
        {
            try { File.AppendAllText(logPath, DateTime.Now.ToString("HH:mm:ss.fff ") + s + "\r\n", new UTF8Encoding(false)); } catch { }
        }

        // 제어 파일에 적힌 지금 명령 (rec / pause / stop). 본체가 꺼졌으면 stop으로 본다.
        static string Command(Process parent)
        {
            if (parent != null && parent.HasExited) return "stop";
            try { return File.ReadAllText(controlPath).Trim().ToLowerInvariant(); } catch { return "rec"; }
        }

        [MTAThread]
        static int Main(string[] args)
        {
            foreach (var a in args)
            {
                int i = a.IndexOf('=');
                if (a.StartsWith("--") && i > 2) A[a.Substring(2, i - 2)] = a.Substring(i + 1);
            }
            string ffmpeg = Arg("ffmpeg", "ffmpeg.exe");
            string outPath = Arg("out", "");
            statusPath = Arg("status", outPath + ".status");
            controlPath = Arg("control", outPath + ".control");
            logPath = Arg("log", outPath + ".log");
            int x = ArgInt("x", 0), y = ArgInt("y", 0), w = ArgInt("w", 1920), h = ArgInt("h", 1080);
            int fps = Math.Max(5, Math.Min(60, ArgInt("fps", 30)));
            w -= w % 2; h -= h % 2; // H.264는 짝수 크기여야 한다
            bool useMic = Arg("mic", "1") == "1", useSys = Arg("sys", "1") == "1";
            Process parent = null;
            try { int pid = ArgInt("parent", 0); if (pid > 0) parent = Process.GetProcessById(pid); } catch { }

            if (outPath == "" || !File.Exists(ffmpeg)) { Status("error 녹화 엔진(ffmpeg.exe)을 찾지 못했습니다."); return 1; }
            string partsDir = outPath + ".parts";
            Directory.CreateDirectory(partsDir);

            // 소리 장치 준비 (없거나 막혀 있으면 그 갈래만 빼고 녹화한다)
            var sources = new List<AudioSource>();
            if (useMic) { var m = new AudioSource("mic"); if (m.Init(false)) sources.Add(m); else Log("mic unavailable"); }
            if (useSys) { var s = new AudioSource("sys"); if (s.Init(true)) sources.Add(s); else Log("system audio unavailable"); }

            string vcodec = PickVideoCodec(ffmpeg, fps);
            long bitrate = Math.Max(2000000L, (long)w * h * fps / 10);
            Log("video " + w + "x" + h + "@" + fps + " " + vcodec + ", audio sources " + sources.Count);

            var parts = new List<string>();
            int seg = 0;
            string cmd = Command(parent);
            while (cmd != "stop")
            {
                if (cmd == "pause") { Status("paused"); while ((cmd = Command(parent)) == "pause") Thread.Sleep(100); continue; }

                // ---- 조각 하나 녹화 ----
                string part = Path.Combine(partsDir, "part" + seg.ToString("000") + ".mp4");
                var sb = new StringBuilder("-hide_banner -loglevel warning -y ");
                sb.Append("-thread_queue_size 1024 -f gdigrab -framerate " + fps + " -offset_x " + x + " -offset_y " + y +
                          " -video_size " + w + "x" + h + " -draw_mouse 1 -i desktop ");
                int pidSelf = Process.GetCurrentProcess().Id;
                foreach (var s in sources)
                {
                    s.BeginSegment("classzoom_" + pidSelf + "_" + s.Name + "_" + seg);
                    sb.Append(s.FfmpegInput());
                }
                if (sources.Count == 2)
                    sb.Append("-filter_complex \"[1:a][2:a]amix=inputs=2:duration=longest:dropout_transition=0:normalize=0[a]\" -map 0:v -map \"[a]\" ");
                else if (sources.Count == 1)
                    sb.Append("-map 0:v -map 1:a ");
                sb.Append(vcodec == "h264_mf" ? "-c:v h264_mf -b:v " + bitrate + " -pix_fmt nv12 " : "-c:v mpeg4 -q:v 3 -pix_fmt yuv420p ");
                if (sources.Count > 0) sb.Append("-c:a aac -b:a 160k -ar 48000 -ac 2 ");
                sb.Append("-movflags +faststart \"" + part + "\"");

                var ff = StartFfmpeg(ffmpeg, sb.ToString());
                if (ff == null) { foreach (var s in sources) s.EndSegment(); Status("error 녹화 엔진을 시작하지 못했습니다."); return 1; }
                Status("recording");
                while ((cmd = Command(parent)) == "rec" && !ff.HasExited) Thread.Sleep(100);
                StopFfmpeg(ff);
                foreach (var s in sources) s.EndSegment();
                if (File.Exists(part) && new FileInfo(part).Length > 0) parts.Add(part);
                else if (ff.HasExited && ff.ExitCode != 0 && cmd == "rec") { Status("error 녹화 중 문제가 생겼습니다. (" + logPath + ")"); return 1; }
                seg++;
            }

            // ---- 조각 잇기 ----
            Status("saving");
            if (parts.Count == 0) { Status("error 녹화된 내용이 없습니다."); return 1; }
            if (parts.Count == 1) File.Copy(parts[0], outPath, true);
            else
            {
                string list = Path.Combine(partsDir, "list.txt");
                var sbl = new StringBuilder();
                foreach (var p in parts) sbl.Append("file '" + p.Replace("'", "'\\''") + "'\n");
                File.WriteAllText(list, sbl.ToString(), new UTF8Encoding(false));
                var cat = StartFfmpeg(ffmpeg, "-hide_banner -loglevel warning -y -f concat -safe 0 -i \"" + list + "\" -c copy -movflags +faststart \"" + outPath + "\"");
                if (cat != null) cat.WaitForExit(600000);
            }
            if (!File.Exists(outPath)) { Status("error 영상 파일을 만들지 못했습니다. (" + logPath + ")"); return 1; }
            try { Directory.Delete(partsDir, true); } catch { }
            Status("done " + outPath);
            return 0;
        }

        // Windows에 들어 있는 H.264 인코더(Media Foundation)를 쓸 수 있으면 그것을, 아니면 MPEG-4로
        static string PickVideoCodec(string ffmpeg, int fps)
        {
            var p = StartFfmpeg(ffmpeg, "-hide_banner -loglevel error -f lavfi -i color=c=black:s=320x240:r=" + fps + ":d=0.5 -c:v h264_mf -pix_fmt nv12 -f null -");
            if (p != null && p.WaitForExit(15000) && p.ExitCode == 0) return "h264_mf";
            Log("h264_mf not available, using mpeg4");
            return "mpeg4";
        }

        static Process StartFfmpeg(string exe, string args)
        {
            Log("ffmpeg " + args);
            var psi = new ProcessStartInfo(exe, args)
            {
                UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardInput = true, RedirectStandardError = true, RedirectStandardOutput = true,
                StandardErrorEncoding = Encoding.UTF8
            };
            try
            {
                var p = new Process { StartInfo = psi };
                p.ErrorDataReceived += (s, e) => { if (e.Data != null) Log("  " + e.Data); };
                p.OutputDataReceived += (s, e) => { };
                p.Start();
                p.BeginErrorReadLine();
                p.BeginOutputReadLine();
                return p;
            }
            catch (Exception ex) { Log("start failed: " + ex.Message); return null; }
        }

        // FFmpeg에 q를 보내면 파일을 제대로 마무리하고 끝난다
        static void StopFfmpeg(Process p)
        {
            if (p.HasExited) return;
            try { p.StandardInput.Write("q"); p.StandardInput.Flush(); } catch { }
            if (!p.WaitForExit(20000)) { try { p.Kill(); } catch { } }
        }
    }
}
