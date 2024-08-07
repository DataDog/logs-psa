using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using NLog;
using NLog.Extensions.Logging;
using System.Xml;

/*

Based on the NLog.Extensions.Logging example from https://github.com/NLog/NLog/wiki/Getting-started-with-.NET-Core-2---Console-application

*/

namespace ConsoleExample
{
    internal static class Program
    {
        static void Main(string[] args)
        {
            var logger = LogManager.GetCurrentClassLogger();
            try
            {
                var config = new ConfigurationBuilder()
                    .SetBasePath(System.IO.Directory.GetCurrentDirectory()) //From NuGet Package Microsoft.Extensions.Configuration.Json
                    .AddJsonFile("appsettings.json", optional: true, reloadOnChange: true)
                    .Build();

                using var servicesProvider = new ServiceCollection()
                    .AddLogging(loggingBuilder =>
                    {
                        // configure Logging with NLog
                        loggingBuilder.ClearProviders();
                        loggingBuilder.SetMinimumLevel(Microsoft.Extensions.Logging.LogLevel.Trace);
                        loggingBuilder.AddNLog(config);
                    }).BuildServiceProvider();

                scenarioOne();

            }
            catch (Exception ex)
            {
                // NLog: catch any exception and log it.
                logger.Error(ex, "Stopped program because of exception");
                throw;
            }
            finally
            {
                // Ensure to flush and stop internal timers/threads before application-exit (Avoid segmentation fault on Linux)
                LogManager.Shutdown();
            }
        }

        /*
            Scenario One - picks off key:values from an XML file and logs them
            as attributes in the log event.
        */
        static void scenarioOne() {
            var nLogLogger = NLog.LogManager.GetCurrentClassLogger();
            XmlDocument doc = new XmlDocument();
            doc.Load("sample.xml");
            if( doc != null && doc.GetElementById("bk101") != null)
            {
                XmlElement? bk101 = doc.GetElementById("bk101");

                if (bk101 != null && bk101.HasChildNodes)
                {
                    XmlNodeList bk101ChildNodes = bk101.ChildNodes;

                    var logEvent = new LogEventInfo(NLog.LogLevel.Info, "XmlLogs", null);

                    /* we don't suggest you log every attribute of the XML file,
                    but this is an example of how you can attach attributes to the log */
                    foreach (XmlNode node in bk101ChildNodes)
                    {
                        logEvent.Properties[node.Name] = node.InnerText;
                    }
                    /* and here's a single arbitrary attribute being added, but you could imagine
                    that it was derived from an XML attribute or element */
                    logEvent.Properties["arbitrary"] = "arbitrary value";

                    logEvent.Message = "Logging from XML - put something useful here, even poor man's debugging: 'Made it this far 1'";

                    nLogLogger.Log(logEvent);
                }
                else
                {
                    nLogLogger.Error("bk101 not found in sample.xml");
                }
            } else
            {
                throw new Exception("Document element is null");
            }
        }
    }
}
