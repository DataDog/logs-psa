import socket
import subprocess

# TCP server configuration
TCP_HOST = '127.0.0.1'  # local dd agent
TCP_PORT = 10518        # tcp listener port

logs = subprocess.run(["bash", "/opt/custom_bash.sh"], capture_output=True, text=True)
# debugging
print(f"logs: {logs.stdout}")
log_lines = logs.stdout.split('\n')
# debugging
print(f"log_lines: {log_lines}")
for log in log_lines:
    if log:
        # debugging
        print(f"log: {log}")
        try:
            # Create a TCP socket
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
                s.connect((TCP_HOST, TCP_PORT))
                s.sendall(log.encode('utf-8'))
        except Exception as e:
            print(f"Error sending '{log}': {e}")
