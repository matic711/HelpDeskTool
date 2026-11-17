// Opomnik - preprost opomnik za dnevna opravila (Windows, .NET Framework 4).
//
// Ob uri opravila se prikaže veliko rdeče okno (privzeto spodaj desno), ki je vedno
// na vrhu, utripa in se ne zapre samo od sebe - klikniti moraš OPRAVLJENO ali ga
// odložiti. Okno ne vzame fokusa, tako da lahko normalno delaš naprej.
//
// Prevede in namesti se z Namesti.bat (uporablja prevajalnik, ki je že v Windows).
// Koda je v C# 5, ker vgrajeni prevajalnik csc.exe novejšega ne podpira.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Management;
using System.Media;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;

[assembly: AssemblyTitle("Opomnik")]
[assembly: AssemblyProduct("Opomnik")]
[assembly: AssemblyDescription("Opomnik za dnevna opravila")]
[assembly: AssemblyVersion("2.0.0.0")]
[assembly: AssemblyFileVersion("2.0.0.0")]

namespace Opomnik
{
    // -----------------------------------------------------------------------
    // Zagon
    // -----------------------------------------------------------------------
    static class Program
    {
        static Mutex mutex;

        [STAThread]
        static void Main(string[] args)
        {
            bool tray = HasArg(args, "/tray");
            bool install = HasArg(args, "/namesti");
            bool uninstall = HasArg(args, "/odstrani");

            if (uninstall)
            {
                Setup.Uninstall();
                return;
            }

            // Samo en primerek naenkrat. Če že teče, mu sporočimo, naj pokaže okno.
            bool createdNew;
            mutex = new Mutex(true, @"Local\Opomnik_App_Mutex", out createdNew);
            EventWaitHandle showEvent = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\Opomnik_App_Show");
            if (!createdNew)
            {
                showEvent.Set();
                return;
            }

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
            Application.ThreadException += (s, e) => Store.Log("Nepričakovana napaka: " + e.Exception);
            AppDomain.CurrentDomain.UnhandledException += (s, e) => Store.Log("Nepričakovana napaka: " + e.ExceptionObject);

            Setup.MigrateFromPowerShellVersion();
            Store.Load();
            if (install) Setup.Install();
            else if (Autostart.IsEnabled) Autostart.Set(true);   // posodobi pot, če je bil program premaknjen

            OpomnikApp app = new OpomnikApp(showEvent, tray && !install, install);
            Application.Run(app);
            GC.KeepAlive(mutex);
        }

        static bool HasArg(string[] args, string name)
        {
            return args.Any(a => string.Equals(a, name, StringComparison.OrdinalIgnoreCase));
        }
    }

    // -----------------------------------------------------------------------
    // Barve
    // -----------------------------------------------------------------------
    static class Theme
    {
        public static readonly Color Red = Color.FromArgb(183, 28, 28);
        public static readonly Color RedLight = Color.FromArgb(211, 47, 47);
        public static readonly Color RedDark = Color.FromArgb(127, 0, 0);
        public static readonly Color Pink = Color.FromArgb(255, 205, 210);
    }

    // -----------------------------------------------------------------------
    // Pomožne funkcije za datume
    // -----------------------------------------------------------------------
    static class Util
    {
        public const string DateFmt = "yyyy-MM-dd HH:mm";

        public static bool TryParseDate(string text, out DateTime date)
        {
            return DateTime.TryParseExact(text ?? "", DateFmt, CultureInfo.InvariantCulture, DateTimeStyles.None, out date);
        }

        public static DateTime ParseDate(string text)
        {
            DateTime d;
            return TryParseDate(text, out d) ? d : DateTime.MaxValue;
        }

        public static string FormatDate(DateTime date)
        {
            return date.ToString(DateFmt, CultureInfo.InvariantCulture);
        }

        public static string FormatTime(DateTime date)
        {
            return date.ToString("HH:mm", CultureInfo.InvariantCulture);
        }

        public static string FormatDay(DateTime date)
        {
            int diff = (date.Date - DateTime.Today).Days;
            if (diff == 0) return "danes";
            if (diff == 1) return "jutri";
            if (diff == -1) return "včeraj";
            return date.ToString("d. M. yyyy", CultureInfo.InvariantCulture);
        }

        public static string FormatWhen(DateTime date)
        {
            return FormatDay(date) + " " + FormatTime(date);
        }

        public static string FormatDuration(int minutes)
        {
            if (minutes < 60) return minutes + " min";
            if (minutes < 1440)
            {
                int h = minutes / 60, m = minutes % 60;
                return m == 0 ? h + " h" : h + " h " + m + " min";
            }
            return (minutes / 1440) + " d";
        }
    }

    // -----------------------------------------------------------------------
    // Podatki (JSON v %APPDATA%\Opomnik - ista datoteka kot prej v PowerShell različici)
    // -----------------------------------------------------------------------
    public class TaskItem
    {
        public string Id { get; set; }
        public string Due { get; set; }
        public string Text { get; set; }
        public bool Done { get; set; }
        public string SnoozeUntil { get; set; }

        [ScriptIgnore]
        public DateTime DueAt { get { return Util.ParseDate(Due); } }

        // kdaj naj se opomnik prikaže (če je bil odložen, šteje čas odloga)
        [ScriptIgnore]
        public DateTime AlertAt { get { return string.IsNullOrEmpty(SnoozeUntil) ? DueAt : Util.ParseDate(SnoozeUntil); } }
    }

    public class AppSettings
    {
        public bool Sound { get; set; }
        public string Position { get; set; }

        public AppSettings()
        {
            Sound = true;
            Position = "BottomRight";
        }
    }

    public class AppData
    {
        public AppSettings Settings { get; set; }
        public List<TaskItem> Tasks { get; set; }
    }

    static class Store
    {
        public static readonly string DataDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Opomnik");
        static readonly string DataFile = Path.Combine(DataDir, "opomnik.json");
        static readonly string LogFile = Path.Combine(DataDir, "napake.log");

        public static readonly string[] PositionKeys = { "BottomRight", "TopRight", "TopCenter", "Center" };
        public static readonly string[] PositionNames = { "spodaj desno", "zgoraj desno", "zgoraj na sredini", "na sredini zaslona" };

        public static AppSettings Settings = new AppSettings();
        public static List<TaskItem> Tasks = new List<TaskItem>();

        public static void Log(string message)
        {
            try
            {
                Directory.CreateDirectory(DataDir);
                File.AppendAllText(LogFile, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture) + "  " + message + Environment.NewLine, Encoding.UTF8);
            }
            catch { }
        }

        public static void Load()
        {
            Tasks.Clear();
            if (!File.Exists(DataFile)) return;
            try
            {
                string raw = File.ReadAllText(DataFile, Encoding.UTF8);
                if (string.IsNullOrWhiteSpace(raw)) return;
                AppData data = new JavaScriptSerializer().Deserialize<AppData>(raw);
                if (data == null) return;

                if (data.Settings != null)
                {
                    Settings.Sound = data.Settings.Sound;
                    if (PositionKeys.Contains(data.Settings.Position)) Settings.Position = data.Settings.Position;
                }

                // opravljena opravila, starejša od 7 dni, pospravimo
                DateTime cutoff = DateTime.Today.AddDays(-7);
                if (data.Tasks == null) return;
                foreach (TaskItem t in data.Tasks)
                {
                    DateTime due, snooze;
                    if (t == null || !Util.TryParseDate(t.Due, out due)) continue;
                    if (t.Done && due < cutoff) continue;
                    if (!Util.TryParseDate(t.SnoozeUntil, out snooze)) t.SnoozeUntil = "";
                    if (string.IsNullOrEmpty(t.Id)) t.Id = Guid.NewGuid().ToString();
                    if (t.Text == null) t.Text = "";
                    Tasks.Add(t);
                }
            }
            catch (Exception ex)
            {
                Log("Datoteke ni bilo mogoče prebrati: " + ex.Message);
                try { File.Copy(DataFile, DataFile + ".pokvarjen", true); } catch { }
            }
        }

        public static void Save()
        {
            try
            {
                Directory.CreateDirectory(DataDir);
                AppData data = new AppData { Settings = Settings, Tasks = Tasks };
                string json = new JavaScriptSerializer().Serialize(data);
                File.WriteAllText(DataFile, json, new UTF8Encoding(false));
            }
            catch (Exception ex)
            {
                Log("Shranjevanje ni uspelo: " + ex.Message);
            }
        }
    }

    // -----------------------------------------------------------------------
    // Samodejni zagon ob prijavi (HKCU\...\Run) in bližnjice
    // -----------------------------------------------------------------------
    static class Autostart
    {
        const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        const string ValueName = "Opomnik";

        public static bool IsEnabled
        {
            get
            {
                try
                {
                    using (RegistryKey k = Registry.CurrentUser.OpenSubKey(RunKey))
                        return k != null && k.GetValue(ValueName) != null;
                }
                catch { return false; }
            }
        }

        public static void Set(bool enable)
        {
            try
            {
                using (RegistryKey k = Registry.CurrentUser.CreateSubKey(RunKey))
                {
                    if (enable) k.SetValue(ValueName, "\"" + Application.ExecutablePath + "\" /tray");
                    else if (k.GetValue(ValueName) != null) k.DeleteValue(ValueName);
                }
            }
            catch (Exception ex)
            {
                Store.Log("Samodejni zagon: " + ex.Message);
            }
        }
    }

    static class Setup
    {
        static string StartMenuLnk { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "Opomnik.lnk"); } }
        static string DesktopLnk { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "Opomnik.lnk"); } }

        // Klic iz Namesti.bat: bližnjici v meniju Start in na namizju + samodejni zagon.
        public static void Install()
        {
            CreateShortcut(StartMenuLnk);
            CreateShortcut(DesktopLnk);
            Autostart.Set(true);
        }

        // Klic iz Odstrani.bat.
        public static void Uninstall()
        {
            Autostart.Set(false);
            try { if (File.Exists(StartMenuLnk)) File.Delete(StartMenuLnk); } catch { }
            try { if (File.Exists(DesktopLnk)) File.Delete(DesktopLnk); } catch { }
        }

        static void CreateShortcut(string lnkPath)
        {
            try
            {
                string exe = Application.ExecutablePath;
                Type shellType = Type.GetTypeFromProgID("WScript.Shell");
                object shell = Activator.CreateInstance(shellType);
                object lnk = shellType.InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { lnkPath });
                Type lt = lnk.GetType();
                lt.InvokeMember("TargetPath", BindingFlags.SetProperty, null, lnk, new object[] { exe });
                lt.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, lnk, new object[] { Path.GetDirectoryName(exe) });
                lt.InvokeMember("IconLocation", BindingFlags.SetProperty, null, lnk, new object[] { exe + ",0" });
                lt.InvokeMember("Description", BindingFlags.SetProperty, null, lnk, new object[] { "Opomnik za dnevna opravila" });
                lt.InvokeMember("Save", BindingFlags.InvokeMethod, null, lnk, null);
                Marshal.ReleaseComObject(lnk);
                Marshal.ReleaseComObject(shell);
            }
            catch (Exception ex)
            {
                Store.Log("Bližnjice " + lnkPath + " ni bilo mogoče ustvariti: " + ex.Message);
            }
        }

        // Prejšnja različica je tekla kot PowerShell skripta. Če še teče, jo ugasnemo
        // (sicer bi dobil vsak opomnik dvakrat), njeno bližnjico za samodejni zagon pa
        // zamenjamo z novim samodejnim zagonom.
        public static void MigrateFromPowerShellVersion()
        {
            try
            {
                using (ManagementObjectSearcher searcher = new ManagementObjectSearcher(
                    "SELECT ProcessId, CommandLine FROM Win32_Process WHERE Name='powershell.exe' OR Name='pwsh.exe'"))
                {
                    foreach (ManagementObject mo in searcher.Get())
                    {
                        string cmd = mo["CommandLine"] as string;
                        if (cmd == null || cmd.IndexOf("Opomnik.ps1", StringComparison.OrdinalIgnoreCase) < 0) continue;
                        try { Process.GetProcessById(Convert.ToInt32(mo["ProcessId"])).Kill(); } catch { }
                    }
                }
            }
            catch (Exception ex)
            {
                Store.Log("Preverjanje stare različice: " + ex.Message);
            }

            try
            {
                string oldLnk = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Startup), "Opomnik.lnk");
                if (File.Exists(oldLnk))
                {
                    File.Delete(oldLnk);
                    Autostart.Set(true);
                }
            }
            catch (Exception ex)
            {
                Store.Log("Stara bližnjica: " + ex.Message);
            }
        }
    }

    // -----------------------------------------------------------------------
    // Glavni del programa: ikona v sistemski vrstici, časovnika in opomnik
    // -----------------------------------------------------------------------
    class OpomnikApp : ApplicationContext
    {
        public readonly Icon AppIcon;
        readonly Icon smallIcon;
        readonly MainForm main;
        readonly NotifyIcon tray;
        readonly System.Windows.Forms.Timer checkTimer;
        readonly System.Windows.Forms.Timer alertTimer;

        PopupForm alertForm;
        TaskItem alertTask;
        bool alertIsTest;
        DateTime alertShownAt;
        int alertTicks;
        DateTime lastSound = DateTime.MinValue;
        DateTime lastDay = DateTime.Today;
        SoundPlayer player;

        public bool ReallyExit { get; private set; }

        public OpomnikApp(EventWaitHandle showEvent, bool startHidden, bool justInstalled)
        {
            AppIcon = LoadIcon(new Size(32, 32));
            smallIcon = LoadIcon(SystemInformation.SmallIconSize);

            main = new MainForm(this);

            // ikona v sistemski vrstici
            ContextMenuStrip menu = new ContextMenuStrip();
            ToolStripItem open = menu.Items.Add("Odpri opomnik", null, (s, e) => ShowMain());
            open.Font = new Font(open.Font, FontStyle.Bold);
            menu.Items.Add("Preizkusi opomnik", null, (s, e) => ShowTestAlert());
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Izhod", null, (s, e) => Exit());
            tray = new NotifyIcon { Icon = smallIcon, Text = "Opomnik", ContextMenuStrip = menu, Visible = true };
            tray.MouseClick += (s, e) => { if (e.Button == MouseButtons.Left) ShowMain(); };

            alertTimer = new System.Windows.Forms.Timer { Interval = 500 };
            alertTimer.Tick += AlertTick;

            checkTimer = new System.Windows.Forms.Timer { Interval = 2000 };
            checkTimer.Tick += CheckTick;

            // če nekdo še enkrat zažene Opomnik, pokažemo okno tega, ki že teče
            SynchronizationContext ui = SynchronizationContext.Current;
            ThreadPool.RegisterWaitForSingleObject(showEvent, (state, timedOut) => ui.Post(_ => ShowMain(), null), null, -1, false);

            if (startHidden) { main.RefreshList(); main.UpdateStatus(); }
            else ShowMain();

            if (justInstalled)
                tray.ShowBalloonTip(6000, "Opomnik je nameščen",
                    "Najdeš ga v meniju Start in na namizju. Zažene se sam ob prijavi v Windows.", ToolTipIcon.Info);

            checkTimer.Start();
        }

        static Icon LoadIcon(Size size)
        {
            try
            {
                using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream("Opomnik.ico"))
                {
                    if (s != null) return new Icon(s, size);
                }
            }
            catch { }
            // rezerva: narišemo rdeč krog s klicajem
            Bitmap bmp = new Bitmap(32, 32);
            using (Graphics g = Graphics.FromImage(bmp))
            using (SolidBrush brush = new SolidBrush(Theme.RedLight))
            using (Font font = new Font("Segoe UI", 22, FontStyle.Bold, GraphicsUnit.Pixel))
            using (StringFormat sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
            {
                g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                g.FillEllipse(brush, 1, 1, 30, 30);
                g.DrawString("!", font, Brushes.White, new RectangleF(0, 0, 32, 32), sf);
            }
            return Icon.FromHandle(bmp.GetHicon());
        }

        public void SetTrayText(string text)
        {
            if (text.Length > 63) text = text.Substring(0, 60) + "...";
            tray.Text = text;
        }

        public void ShowTrayHint()
        {
            tray.ShowBalloonTip(5000, "Opomnik teče naprej v ozadju",
                "Najdeš ga spodaj desno ob uri. Za izhod: desni klik na ikono > Izhod.", ToolTipIcon.Info);
        }

        public void ShowMain()
        {
            main.Show();
            if (main.WindowState == FormWindowState.Minimized) main.WindowState = FormWindowState.Normal;
            // kratek TopMost trik, da okno zares pride v ospredje
            main.TopMost = true;
            main.TopMost = false;
            main.Activate();
            main.RefreshList();
            main.UpdateStatus();
        }

        public void Exit()
        {
            int pending = Store.Tasks.Count(t => !t.Done);
            if (pending > 0)
            {
                DialogResult r = MessageBox.Show(
                    "Neopravljenih opravil: " + pending + ".\nČe zapreš Opomnik, te ne bo več opominjal.\n\nRes zaprem?",
                    "Opomnik", MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
                if (r != DialogResult.Yes) return;
            }
            ReallyExit = true;
            checkTimer.Stop();
            if (alertTask != null) CloseAlert(null, 0);
            tray.Visible = false;
            tray.Dispose();
            main.Close();
            ExitThread();
        }

        // vsaki 2 s: ali je kakšno opravilo na vrsti?
        void CheckTick(object sender, EventArgs e)
        {
            try
            {
                if (DateTime.Today != lastDay)
                {
                    lastDay = DateTime.Today;
                    main.OnNewDay();
                }

                if (IsAlertObsolete()) CloseAlert(null, 0);

                if (alertTask == null)
                {
                    DateTime now = DateTime.Now;
                    TaskItem next = Store.Tasks.Where(t => !t.Done && t.AlertAt <= now).OrderBy(t => t.AlertAt).FirstOrDefault();
                    if (next != null) ShowAlert(next, false);
                }
                main.UpdateStatus();
            }
            catch (Exception ex)
            {
                Store.Log("CheckTimer: " + ex);
            }
        }

        // Če je opravilo z opomnika medtem izbrisano ali označeno kot opravljeno
        // v glavnem oknu, opomnik zapremo.
        public bool IsAlertObsolete()
        {
            if (alertTask == null || alertIsTest) return false;
            return alertTask.Done || !Store.Tasks.Contains(alertTask);
        }

        public bool AlertVisible { get { return alertTask != null; } }

        public void ShowTestAlert()
        {
            if (alertTask != null) return;
            TaskItem fake = new TaskItem
            {
                Id = "",
                Due = Util.FormatDate(DateTime.Now),
                Text = "Tako izgleda opomnik. Klikni OPRAVLJENO ali ga odloži.",
                SnoozeUntil = ""
            };
            ShowAlert(fake, true);
        }

        void ShowAlert(TaskItem task, bool test)
        {
            alertTask = task;
            alertIsTest = test;
            alertShownAt = DateTime.Now;
            alertTicks = 0;

            string head;
            if (test)
            {
                head = "OPOMNIK  ·  preizkus";
            }
            else
            {
                DateTime now = DateTime.Now;
                head = "OPOMNIK  ·  " + Util.FormatWhen(task.DueAt);
                int late = (int)Math.Floor((now - task.DueAt).TotalMinutes);
                if (late >= 2) head += "  ·  zamuda " + Util.FormatDuration(late);
                int others = Store.Tasks.Count(t => !t.Done && t != task && t.AlertAt <= now);
                if (others > 0) head += "  ·  še " + others + " v vrsti";
            }

            try
            {
                alertForm = new PopupForm(this, head, task.Text);
                PositionAlert();
                alertForm.Show();
                PlaySound();
                alertTimer.Start();
            }
            catch (Exception ex)
            {
                // rezerva: če okna ni mogoče prikazati, vsaj navadno sporočilo na vrhu
                Store.Log("Prikaz opomnika ni uspel: " + ex);
                if (alertForm != null)
                {
                    alertForm.AllowClose = true;
                    try { alertForm.Close(); } catch { }
                    alertForm = null;
                }
                MessageBox.Show(task.Text, "OPOMNIK", MessageBoxButtons.OK, MessageBoxIcon.Warning,
                    MessageBoxDefaultButton.Button1, MessageBoxOptions.ServiceNotification);
                CloseAlert("done", 0);
            }
        }

        // action: "done", "snooze" ali null (samo zapri)
        public void CloseAlert(string action, int minutes)
        {
            TaskItem task = alertTask;
            if (task != null && !alertIsTest && action != null)
            {
                if (action == "done")
                {
                    task.Done = true;
                    task.SnoozeUntil = "";
                }
                else if (action == "snooze")
                {
                    task.SnoozeUntil = Util.FormatDate(DateTime.Now.AddMinutes(minutes));
                }
                Store.Save();
            }
            alertTimer.Stop();
            StopSound();
            if (alertForm != null)
            {
                alertForm.AllowClose = true;
                alertForm.Close();
                alertForm = null;
            }
            alertTask = null;
            main.RefreshList();
            main.UpdateStatus();
        }

        public void PositionAlert()
        {
            if (alertForm == null) return;
            Rectangle wa = Screen.PrimaryScreen.WorkingArea;
            int m = 16, w = alertForm.Width, h = alertForm.Height, x, y;
            switch (Store.Settings.Position)
            {
                case "TopRight":  x = wa.Right - w - m;           y = wa.Top + m; break;
                case "TopCenter": x = wa.Left + (wa.Width - w) / 2; y = wa.Top + m; break;
                case "Center":    x = wa.Left + (wa.Width - w) / 2; y = wa.Top + (wa.Height - h) / 2; break;
                default:          x = wa.Right - w - m;           y = wa.Bottom - h - m; break;
            }
            alertForm.Location = new Point(x, y);
        }

        // 2x na sekundo, dokler je opomnik odprt
        void AlertTick(object sender, EventArgs e)
        {
            try
            {
                PopupForm f = alertForm;
                if (f == null) return;
                alertTicks++;

                // gumbi začnejo delovati po 1 s (da ga ne potrdiš po nesreči)
                if ((DateTime.Now - alertShownAt).TotalSeconds >= 1) f.EnableButtons();

                // počasno utripanje (vsako sekundo)
                if (alertTicks % 2 == 0) f.BackColor = (alertTicks % 4 == 0) ? Theme.Red : Theme.RedLight;

                // vsake 3 s: če ga je kaj prekrilo ali skrilo, ga vrnemo na vrh (brez kraje fokusa)
                if (alertTicks % 6 == 0)
                {
                    if (f.WindowState == FormWindowState.Minimized) f.WindowState = FormWindowState.Normal;
                    f.KeepOnTop();
                }

                // zvonec se ponovi vsaki 2 minuti, dokler ne potrdiš
                if ((DateTime.Now - lastSound).TotalSeconds >= 120) PlaySound();
            }
            catch (Exception ex)
            {
                Store.Log("AlertTimer: " + ex.Message);
            }
        }

        // kratek zvonec (ne dolg alarm - da ne moti, če si na klicu)
        void PlaySound()
        {
            lastSound = DateTime.Now;
            if (!Store.Settings.Sound) return;
            try
            {
                if (player == null)
                {
                    string media = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "Media");
                    foreach (string name in new[] { "Windows Notify Calendar.wav", "Windows Notify System Generic.wav", "Alarm01.wav" })
                    {
                        string wav = Path.Combine(media, name);
                        if (File.Exists(wav)) { player = new SoundPlayer(wav); break; }
                    }
                }
                if (player != null) player.Play();
                else SystemSounds.Exclamation.Play();
            }
            catch { }
        }

        void StopSound()
        {
            try { if (player != null) player.Stop(); } catch { }
        }
    }

    // -----------------------------------------------------------------------
    // Okno z opomnikom: vedno na vrhu, a se pokaže BREZ kraje fokusa
    // -----------------------------------------------------------------------
    class PopupForm : Form
    {
        const int W = 590, H = 300;
        public bool AllowClose;
        readonly List<Button> buttons = new List<Button>();
        Point? dragOffset;

        [DllImport("user32.dll")]
        static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int x, int y, int cx, int cy, uint flags);

        public PopupForm(OpomnikApp app, string head, string text)
        {
            Text = "Opomnik";
            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.Manual;
            ShowInTaskbar = false;
            ClientSize = new Size(W, H);
            BackColor = Theme.Red;
            Icon = app.AppIcon;
            Cursor = Cursors.SizeAll;
            DoubleBuffered = true;
            AddDrag(this);

            // zgornja vrstica: OPOMNIK · danes 14:30 · zamuda ...
            AddLabel(head, new Font("Segoe UI", 11, FontStyle.Bold), Theme.Pink, new Rectangle(20, 14, W - 40, 26));

            // besedilo opravila - čim večje
            AddLabel(text, FitFont(text, W - 50, 134, 30, 12), Color.White, new Rectangle(20, 44, W - 40, 140));

            Button done = AddButton("OPRAVLJENO", new Font("Segoe UI", 18, FontStyle.Bold), Color.White, Theme.Red, new Rectangle(20, 198, 250, 82));
            done.FlatAppearance.BorderSize = 0;
            done.Click += (s, e) => app.CloseAlert("done", 0);

            AddLabel("Odloži za:", new Font("Segoe UI", 9), Theme.Pink, new Rectangle(290, 196, 280, 22));
            int[] minutes = { 5, 15, 60 };
            string[] labels = { "5 min", "15 min", "1 uro" };
            for (int i = 0; i < minutes.Length; i++)
            {
                int min = minutes[i];
                Button b = AddButton(labels[i], new Font("Segoe UI", 12), Theme.RedDark, Color.White, new Rectangle(290 + i * 96, 220, 88, 60));
                b.FlatAppearance.BorderColor = Theme.Pink;
                b.FlatAppearance.BorderSize = 2;
                b.Click += (s, e) => app.CloseAlert("snooze", min);
            }
        }

        protected override bool ShowWithoutActivation { get { return true; } }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= 0x08000000;     // WS_EX_NOACTIVATE - ne vzame fokusa
                cp.ExStyle |= 0x00000080;     // WS_EX_TOOLWINDOW - ni v Alt+Tab
                cp.ExStyle |= 0x00000008;     // WS_EX_TOPMOST    - vedno na vrhu
                cp.ClassStyle |= 0x00020000;  // CS_DROPSHADOW    - senca
                return cp;
            }
        }

        // spet na vrh (HWND_TOPMOST), brez aktiviranja
        public void KeepOnTop()
        {
            try
            {
                if (IsHandleCreated)
                    SetWindowPos(Handle, new IntPtr(-1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010 | 0x0040);
            }
            catch { }
        }

        public void EnableButtons()
        {
            foreach (Button b in buttons) if (!b.Enabled) b.Enabled = true;
        }

        // Alt+F4 ne deluje - zapre se samo z gumbom
        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            if (!AllowClose && e.CloseReason != CloseReason.WindowsShutDown) e.Cancel = true;
            base.OnFormClosing(e);
        }

        // svetel rob okoli okna
        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            using (Pen pen = new Pen(Theme.Pink, 4))
                e.Graphics.DrawRectangle(pen, 2, 2, ClientSize.Width - 4, ClientSize.Height - 4);
        }

        void AddLabel(string text, Font font, Color color, Rectangle bounds)
        {
            Label l = new Label
            {
                Text = text,
                Font = font,
                ForeColor = color,
                BackColor = Color.Transparent,
                TextAlign = ContentAlignment.MiddleLeft,
                AutoSize = false,
                UseMnemonic = false,
                Bounds = bounds
            };
            AddDrag(l);
            Controls.Add(l);
        }

        Button AddButton(string text, Font font, Color back, Color fore, Rectangle bounds)
        {
            Button b = new Button
            {
                Text = text,
                Font = font,
                BackColor = back,
                ForeColor = fore,
                FlatStyle = FlatStyle.Flat,
                Cursor = Cursors.Hand,
                Enabled = false,
                Bounds = bounds,
                TabStop = false
            };
            buttons.Add(b);
            Controls.Add(b);
            return b;
        }

        // okno lahko z miško povlečeš kamorkoli
        void AddDrag(Control c)
        {
            c.MouseDown += (s, e) =>
            {
                if (e.Button == MouseButtons.Left)
                    dragOffset = new Point(System.Windows.Forms.Cursor.Position.X - Left, System.Windows.Forms.Cursor.Position.Y - Top);
            };
            c.MouseMove += (s, e) =>
            {
                if (dragOffset.HasValue && e.Button == MouseButtons.Left)
                    Location = new Point(System.Windows.Forms.Cursor.Position.X - dragOffset.Value.X, System.Windows.Forms.Cursor.Position.Y - dragOffset.Value.Y);
            };
            c.MouseUp += (s, e) => { dragOffset = null; };
        }

        // največja pisava, pri kateri se besedilo še prilega v okvir
        static Font FitFont(string text, int maxWidth, int maxHeight, int startSize, int minSize)
        {
            for (int size = startSize; size > minSize; size -= 2)
            {
                Font f = new Font("Segoe UI", size, FontStyle.Bold);
                Size measured = TextRenderer.MeasureText(text, f, new Size(maxWidth, 0), TextFormatFlags.WordBreak);
                if (measured.Height <= maxHeight && measured.Width <= maxWidth) return f;
                f.Dispose();
            }
            return new Font("Segoe UI", minSize, FontStyle.Bold);
        }
    }

    // -----------------------------------------------------------------------
    // Glavno okno: seznam opravil
    // -----------------------------------------------------------------------
    class MainForm : Form
    {
        readonly OpomnikApp app;
        readonly DateTimePicker dtDate, dtTime;
        readonly TextBox txtTask;
        readonly ListView lv;
        readonly Label lblStatus;
        readonly Font strikeFont;
        bool trayHintShown;

        public MainForm(OpomnikApp app)
        {
            this.app = app;
            Text = "Opomnik";
            Icon = app.AppIcon;
            StartPosition = FormStartPosition.CenterScreen;
            Font = new Font("Segoe UI", 10);
            ClientSize = new Size(660, 550);
            MinimumSize = new Size(580, 450);
            strikeFont = new Font(Font, FontStyle.Strikeout);

            // --- vrstica 1: dan + ura
            AddLabel("Dan:", 12, 16);
            dtDate = new DateTimePicker { Format = DateTimePickerFormat.Short, Location = new Point(52, 12), Width = 130 };
            Controls.Add(dtDate);

            AddLabel("Ura:", 200, 16);
            dtTime = new DateTimePicker
            {
                Format = DateTimePickerFormat.Custom,
                CustomFormat = "HH:mm",
                ShowUpDown = true,
                Location = new Point(238, 12),
                Width = 80
            };
            DateTime start = DateTime.Now.AddMinutes(30);
            dtTime.Value = start.Date.AddHours(start.Hour).AddMinutes(Math.Ceiling(start.Minute / 5.0) * 5);
            Controls.Add(dtTime);

            // --- vrstica 2: besedilo + Dodaj
            txtTask = new TextBox { Location = new Point(12, 50), Width = 520, Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right };
            Controls.Add(txtTask);

            Button btnAdd = AddButton("Dodaj", 542, 48, 106, 30, AnchorStyles.Top | AnchorStyles.Right);
            btnAdd.Click += (s, e) => AddTask();
            AcceptButton = btnAdd;

            Label hint = AddLabel("Namig: napišeš lahko kar \"14:30 Pokliči stranko\" in ura se nastavi sama. Enter = dodaj.", 12, 84);
            hint.ForeColor = Color.Gray;
            hint.Font = new Font("Segoe UI", 9);

            // --- seznam opravil
            lv = new ListView
            {
                View = View.Details,
                FullRowSelect = true,
                HideSelection = false,
                MultiSelect = true,
                Location = new Point(12, 108),
                Size = new Size(636, 300),
                Anchor = AnchorStyles.Top | AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right
            };
            lv.Columns.Add("Kdaj", 120);
            lv.Columns.Add("Opravilo", 375);
            lv.Columns.Add("Stanje", 120);
            lv.Resize += (s, e) =>
            {
                int w = lv.ClientSize.Width - lv.Columns[0].Width - lv.Columns[2].Width - 4;
                if (w > 100) lv.Columns[1].Width = w;
            };
            lv.KeyDown += (s, e) => { if (e.KeyCode == Keys.Delete) RemoveSelected(); };
            Controls.Add(lv);

            // --- gumbi pod seznamom
            AnchorStyles bl = AnchorStyles.Bottom | AnchorStyles.Left;
            AddButton("Opravljeno", 12, 418, 120, 32, bl).Click += (s, e) => ToggleSelectedDone();
            AddButton("Izbriši", 140, 418, 100, 32, bl).Click += (s, e) => RemoveSelected();
            AddButton("Preizkusi opomnik", 248, 418, 160, 32, bl).Click += (s, e) => app.ShowTestAlert();
            AddButton("Izhod", 548, 418, 100, 32, AnchorStyles.Bottom | AnchorStyles.Right).Click += (s, e) => app.Exit();

            // --- nastavitve
            CheckBox chkSound = new CheckBox { Text = "Zvok ob opomniku", AutoSize = true, Location = new Point(14, 460), Anchor = bl, Checked = Store.Settings.Sound };
            chkSound.Click += (s, e) => { Store.Settings.Sound = chkSound.Checked; Store.Save(); };
            Controls.Add(chkSound);

            CheckBox chkAuto = new CheckBox { Text = "Zaženi ob prijavi v Windows", AutoSize = true, Location = new Point(200, 460), Anchor = bl, Checked = Autostart.IsEnabled };
            chkAuto.Click += (s, e) => { Autostart.Set(chkAuto.Checked); chkAuto.Checked = Autostart.IsEnabled; };
            Controls.Add(chkAuto);

            Label lblPos = AddLabel("Kje se pokaže opomnik:", 12, 492);
            lblPos.Anchor = bl;
            ComboBox cmbPos = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Location = new Point(180, 488), Width = 180, Anchor = bl };
            cmbPos.Items.AddRange(Store.PositionNames);
            cmbPos.SelectedIndex = Math.Max(0, Array.IndexOf(Store.PositionKeys, Store.Settings.Position));
            cmbPos.SelectedIndexChanged += (s, e) =>
            {
                Store.Settings.Position = Store.PositionKeys[cmbPos.SelectedIndex];
                Store.Save();
                app.PositionAlert();
            };
            Controls.Add(cmbPos);

            // --- statusna vrstica
            lblStatus = new Label
            {
                AutoSize = false,
                UseMnemonic = false,
                Location = new Point(12, 522),
                Size = new Size(636, 24),
                Anchor = AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right,
                Font = new Font("Segoe UI", 10, FontStyle.Bold)
            };
            Controls.Add(lblStatus);
        }

        Label AddLabel(string text, int x, int y)
        {
            Label l = new Label { Text = text, AutoSize = true, Location = new Point(x, y) };
            Controls.Add(l);
            return l;
        }

        Button AddButton(string text, int x, int y, int w, int h, AnchorStyles anchor)
        {
            Button b = new Button { Text = text, Location = new Point(x, y), Size = new Size(w, h), Anchor = anchor };
            Controls.Add(b);
            return b;
        }

        // Križec (X) ne zapre programa, samo skrije okno v sistemsko vrstico.
        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            if (!app.ReallyExit && e.CloseReason == CloseReason.UserClosing)
            {
                e.Cancel = true;
                Hide();
                if (!trayHintShown)
                {
                    trayHintShown = true;
                    app.ShowTrayHint();
                }
            }
            base.OnFormClosing(e);
        }

        public void OnNewDay()
        {
            dtDate.Value = DateTime.Today;
            RefreshList();
        }

        List<string> SelectedIds()
        {
            return lv.SelectedItems.Cast<ListViewItem>().Select(i => (string)i.Tag).ToList();
        }

        public void RefreshList()
        {
            List<string> selected = SelectedIds();
            DateTime now = DateTime.Now;
            lv.BeginUpdate();
            try
            {
                lv.Items.Clear();
                // vsa neopravljena + današnja/prihodnja opravljena
                foreach (TaskItem t in Store.Tasks.Where(t => !t.Done || t.DueAt >= DateTime.Today).OrderBy(t => t.DueAt))
                {
                    ListViewItem item = new ListViewItem(Util.FormatWhen(t.DueAt)) { Tag = t.Id };
                    item.SubItems.Add(t.Text);
                    string status;
                    if (t.Done)
                    {
                        status = "opravljeno";
                        item.ForeColor = Color.Gray;
                        item.Font = strikeFont;
                    }
                    else if (!string.IsNullOrEmpty(t.SnoozeUntil) && t.AlertAt > now)
                    {
                        status = "odloženo do " + Util.FormatTime(t.AlertAt);
                        item.ForeColor = Color.DarkOrange;
                    }
                    else if (t.DueAt <= now)
                    {
                        status = "ZDAJ";
                        item.ForeColor = Color.Firebrick;
                    }
                    else
                    {
                        status = "čaka";
                    }
                    item.SubItems.Add(status);
                    lv.Items.Add(item);
                    if (selected.Contains(t.Id)) item.Selected = true;
                }
            }
            finally
            {
                lv.EndUpdate();
            }
        }

        public void UpdateStatus()
        {
            DateTime now = DateTime.Now;
            TaskItem next = Store.Tasks.Where(t => !t.Done).OrderBy(t => t.AlertAt).FirstOrDefault();
            if (next != null)
            {
                DateTime at = next.AlertAt;
                int mins = (int)Math.Ceiling((at - now).TotalMinutes);
                string inTime = mins <= 0 ? "zdaj" : "čez " + Util.FormatDuration(mins);
                lblStatus.Text = "Naslednji opomnik: " + Util.FormatWhen(at) + " - " + next.Text + "  (" + inTime + ")";
                app.SetTrayText("Opomnik - " + Util.FormatTime(at) + " " + next.Text);
            }
            else
            {
                lblStatus.Text = "Ni čakajočih opravil.";
                app.SetTrayText("Opomnik - ni čakajočih opravil");
            }
        }

        void AddTask()
        {
            string text = txtTask.Text.Trim();
            if (text.Length == 0) { txtTask.Focus(); return; }

            int hour = dtTime.Value.Hour, minute = dtTime.Value.Minute;

            // "14:30 Pokliči stranko" -> ura se prebere kar iz besedila
            Match m = Regex.Match(text, @"^(\d{1,2})[:.](\d{2})\s+(.+)$");
            if (m.Success)
            {
                int hh = int.Parse(m.Groups[1].Value), mm = int.Parse(m.Groups[2].Value);
                if (hh <= 23 && mm <= 59)
                {
                    hour = hh;
                    minute = mm;
                    text = m.Groups[3].Value.Trim();
                }
            }

            DateTime due = dtDate.Value.Date.AddHours(hour).AddMinutes(minute);
            if (due < DateTime.Now.AddMinutes(-1))
            {
                DialogResult r = MessageBox.Show(
                    "Čas " + Util.FormatWhen(due) + " je že mimo, zato se bo opomnik prikazal takoj.\n\nDodam vseeno?",
                    "Opomnik", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
                if (r != DialogResult.Yes) return;
            }

            Store.Tasks.Add(new TaskItem
            {
                Id = Guid.NewGuid().ToString(),
                Due = Util.FormatDate(due),
                Text = text,
                Done = false,
                SnoozeUntil = ""
            });
            Store.Save();
            RefreshList();
            UpdateStatus();
            txtTask.Clear();
            txtTask.Focus();
        }

        void ToggleSelectedDone()
        {
            List<string> ids = SelectedIds();
            List<TaskItem> sel = Store.Tasks.Where(t => ids.Contains(t.Id)).ToList();
            if (sel.Count == 0) return;
            // če so vsa izbrana že opravljena, jih vrnemo nazaj med čakajoča
            bool allDone = sel.All(t => t.Done);
            foreach (TaskItem t in sel)
            {
                t.Done = !allDone;
                t.SnoozeUntil = "";
            }
            Store.Save();
            if (app.IsAlertObsolete()) app.CloseAlert(null, 0);
            RefreshList();
            UpdateStatus();
        }

        void RemoveSelected()
        {
            List<string> ids = SelectedIds();
            if (ids.Count == 0) return;
            string what = ids.Count == 1 ? "izbrano opravilo" : "izbrana opravila (" + ids.Count + ")";
            if (MessageBox.Show("Izbrišem " + what + "?", "Opomnik", MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;
            Store.Tasks.RemoveAll(t => ids.Contains(t.Id));
            Store.Save();
            if (app.IsAlertObsolete()) app.CloseAlert(null, 0);
            RefreshList();
            UpdateStatus();
        }
    }
}
