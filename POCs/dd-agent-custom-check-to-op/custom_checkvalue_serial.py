from checks import AgentCheck
from datadog_checks.base.utils.subprocess_output import get_subprocess_output
import socket

class BashCheck(AgentCheck):
    def check(self, instance):
        # TCP server configuration
        TCP_HOST = '127.0.0.1'  # local dd agent
        TCP_PORT = 10518        # tcp listener port

        # for loop to loop 30 times to collect logs serially.
        # In a real scenario, you wouldn't loop and you'd call different
        # bash scripts or commands in sequence in this check, but for the
        # purposes of proof-of-concept, this should behave the same way
        for i in range(30):
            try:
                logs = get_subprocess_output(["bash", "/opt/custom_bash.sh"], self.log, raise_on_empty_output=True)
                # Create a TCP socket
                with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
                    s.connect((TCP_HOST, TCP_PORT))
                    s.sendall(logs[0].encode('utf-8'))
            except Exception as e:
                print(f"Error collecting logs: {e}")
