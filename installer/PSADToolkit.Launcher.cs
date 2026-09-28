// PSADToolkit.exe : point d entree de l application installee.
//
// Demarre Launcher.ps1 avec Windows PowerShell 5.1, sans fenetre de console. Le
// lanceur verifie et installe les prerequis (PowerShell 7, GliderUI), affiche sa
// propre fenetre d attente, puis ouvre l interface. Cet executable ne fait rien
// d autre : toute la logique reste lisible et modifiable dans les scripts.
//
// Compile par installer\Build-Installer.ps1 avec le compilateur C# du .NET
// Framework 4, present sur tout Windows :
//   csc.exe /target:winexe /platform:anycpu /win32icon:PSADToolkit.ico ...
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

[assembly: AssemblyTitle("PSADToolkit")]
[assembly: AssemblyProduct("PSADToolkit")]
[assembly: AssemblyDescription("Administration Active Directory")]
[assembly: AssemblyCompany("PSADToolkit")]
[assembly: AssemblyCopyright("Licence MIT")]
[assembly: AssemblyVersion("0.0.0.0")]
[assembly: AssemblyFileVersion("0.0.0.0")]
[assembly: AssemblyInformationalVersion("0.0.0")]

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        string folder = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(folder, "Launcher.ps1");
        if (!File.Exists(script))
        {
            MessageBox.Show("Fichier introuvable : " + script + Environment.NewLine + Environment.NewLine +
                "Reinstaller PSADToolkit.", "PSADToolkit", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 2;
        }

        // Toujours le Windows PowerShell 64 bits du systeme : un processus 32 bits
        // passe par Sysnative pour echapper a la redirection de System32.
        string windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        string system = (Environment.Is64BitOperatingSystem && !Environment.Is64BitProcess) ? "Sysnative" : "System32";
        string powershell = Path.Combine(windows, system + @"\WindowsPowerShell\v1.0\powershell.exe");
        if (!File.Exists(powershell))
        {
            MessageBox.Show("Windows PowerShell est introuvable : " + powershell, "PSADToolkit",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 3;
        }

        StringBuilder arguments = new StringBuilder();
        arguments.Append("-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File ");
        arguments.Append(Quote(script));
        foreach (string argument in args)
        {
            // Seuls les commutateurs du lanceur sont transmis (-NoUpdate, -Offline...).
            if (argument.Length > 1 && argument[0] == '-' && IsSimple(argument))
            {
                arguments.Append(' ').Append(argument);
            }
        }

        ProcessStartInfo start = new ProcessStartInfo(powershell, arguments.ToString());
        start.UseShellExecute = false;
        start.CreateNoWindow = true;
        // Dossier de travail hors du dossier d installation : un processus qui y
        // travaille le verrouillerait et empecherait la desinstallation de le retirer.
        start.WorkingDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        try
        {
            using (Process process = Process.Start(start))
            {
                process.WaitForExit();
                return process.ExitCode;
            }
        }
        catch (Exception error)
        {
            MessageBox.Show("Demarrage impossible : " + error.Message, "PSADToolkit",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    private static bool IsSimple(string value)
    {
        foreach (char c in value)
        {
            if (!(char.IsLetterOrDigit(c) || c == '-')) { return false; }
        }
        return true;
    }

    private static string Quote(string value)
    {
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }
}
