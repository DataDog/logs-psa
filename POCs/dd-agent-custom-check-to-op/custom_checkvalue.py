from checks import AgentCheck
from datadog_checks.base.utils.subprocess_output import get_subprocess_output
import socket

class BashCheck(AgentCheck):
    def check(self, instance):
        # TCP server configuration
        TCP_HOST = '127.0.0.1'  # local dd agent
        TCP_PORT = 10518        # tcp listener port

        logs = get_subprocess_output(["bash", "/opt/custom_bash.sh"], self.log, raise_on_empty_output=True)
        for log in logs:
            if log:
                try:
                    # Create a TCP socket
                    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
                        s.connect((TCP_HOST, TCP_PORT))
                        s.sendall(log.encode('utf-8'))
                except Exception as e:
                    print(f"Error sending '{log}': {e}")
