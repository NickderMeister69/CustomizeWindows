// Win11 Customizer - Starter (.exe)
// Enthaelt beide PowerShell-Skripte, entpackt sie nach %LOCALAPPDATA%\Win11Customizer\app
// und startet sie unsichtbar (ohne Konsolenfenster).
//   Win11 Customizer.exe           -> Einstellungs-App
//   Win11 Customizer.exe --tiles   -> nur die Desktop-Kacheln (fuer den Autostart)
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

[assembly: AssemblyTitle("Win11 Customizer")]
[assembly: AssemblyDescription("Windows 11 komplett anpassen")]
[assembly: AssemblyProduct("Win11 Customizer")]
[assembly: AssemblyCompany("Nick")]
[assembly: AssemblyCopyright("Nick 2026")]
[assembly: AssemblyVersion("1.2.0.0")]
[assembly: AssemblyFileVersion("1.2.0.0")]

static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        try
        {
            string dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Win11Customizer", "app");
            Directory.CreateDirectory(dir);
            Extract("Win11Customizer.ps1", dir);
            Extract("DesktopTiles.ps1", dir);

            bool tiles = args.Length > 0 && args[0].Equals("--tiles", StringComparison.OrdinalIgnoreCase);
            string script = Path.Combine(dir, tiles ? "DesktopTiles.ps1" : "Win11Customizer.ps1");
            string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
            if (!File.Exists(ps)) throw new FileNotFoundException("Windows PowerShell wurde nicht gefunden: " + ps);

            var psi = new ProcessStartInfo(ps, "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" + script + "\"");
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.WorkingDirectory = dir;
            psi.EnvironmentVariables["W11C_EXE"] = Application.ExecutablePath;
            Process.Start(psi);
            return 0;
        }
        catch (Exception ex)
        {
            MessageBox.Show("Win11 Customizer konnte nicht gestartet werden:\n\n" + ex.Message,
                            "Win11 Customizer", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    static void Extract(string name, string dir)
    {
        Assembly asm = Assembly.GetExecutingAssembly();
        using (Stream s = asm.GetManifestResourceStream(name))
        {
            if (s == null) throw new Exception("Interne Datei fehlt: " + name);
            byte[] data = new byte[s.Length];
            int read = 0;
            while (read < data.Length)
            {
                int n = s.Read(data, read, data.Length - read);
                if (n <= 0) break;
                read += n;
            }
            string target = Path.Combine(dir, name);
            if (File.Exists(target) && Same(File.ReadAllBytes(target), data)) return;
            string tmp = target + ".tmp";
            File.WriteAllBytes(tmp, data);
            if (File.Exists(target)) File.Delete(target);
            File.Move(tmp, target);
        }
    }

    static bool Same(byte[] a, byte[] b)
    {
        if (a.Length != b.Length) return false;
        for (int i = 0; i < a.Length; i++) if (a[i] != b[i]) return false;
        return true;
    }
}
