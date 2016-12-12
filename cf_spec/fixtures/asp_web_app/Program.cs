using System.IO;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.Configuration;

namespace HelloWeb
{
    public class Program
    {
        public static void Main(string[] args)
        {

            var config = new ConfigurationBuilder()
                          .AddCommandLine(args)
                          .Build();
            var host = new WebHostBuilder()
                        .UseKestrel(options =>
                        {
                            options.UseConnectionLogging();
                        })
                        .UseConfiguration(config)
                        .UseContentRoot(Directory.GetCurrentDirectory())
                        .UseStartup<Startup>()
                        .Build();

            host.Run();
        }
    }
}
