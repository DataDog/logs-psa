from checks import AgentCheck
from datadog_checks.base.utils.subprocess_output import get_subprocess_output
import socket

class BashCheck(AgentCheck):
    def check(self, instance):
        # TCP server configuration
        TCP_HOST = '127.0.0.1'  # local dd agent
        TCP_PORT = 10518        # tcp listener port

        all_logs = []

        # for loop to loop 30 times to collect logs serially
        # in a real scenario, you wouldn't loop and you'd call different
        # bash scripts or commands
        for i in range(30):
            try:
                logs = get_subprocess_output(["bash", "/opt/custom_bash.sh"], self.log, raise_on_empty_output=True)
                all_logs += logs.splitlines()
            except Exception as e:
                self.log.error(f"Error collecting logs: {e}")

        for log in all_logs:
            if log:
                try:
                    # Create a TCP socket
                    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
                        s.connect((TCP_HOST, TCP_PORT))
                        s.sendall(log.encode('utf-8'))
                except Exception as e:
                    print(f"Error sending '{log}': {e}")
