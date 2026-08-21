using System;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using Microsoft.PowerShell;

class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(dir, "n8n.ps1");
        if (!File.Exists(script))
        {
            Console.Error.WriteLine("Missing n8n.ps1: " + script);
            return 1;
        }
        try
        {
            InitialSessionState iss = InitialSessionState.CreateDefault2();
            iss.ExecutionPolicy = ExecutionPolicy.Bypass;
            using (PowerShell ps = PowerShell.Create(iss))
            {
                ps.AddCommand(script);
                for (int i = 0; i < args.Length; i++)
                {
                    string a = args[i];
                    if (a.StartsWith("-") && a.Length > 1)
                    {
                        string name = a.TrimStart('-');
                        if (i + 1 < args.Length && !args[i + 1].StartsWith("-"))
                        {
                            ps.AddParameter(name, args[i + 1]);
                            i++;
                        }
                        else
                        {
                            ps.AddParameter(name);
                        }
                    }
                }
                ps.Invoke();
                if (ps.HadErrors) return 1;
            }
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("Error: " + ex.Message);
            return 1;
        }
    }
}
