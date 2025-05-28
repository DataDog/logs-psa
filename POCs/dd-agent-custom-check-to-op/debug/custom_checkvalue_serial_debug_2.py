import subprocess
import socket

# TCP server configuration
TCP_HOST = '127.0.0.1'  # local dd agent
TCP_PORT = 10518        # tcp listener port

# for loop to loop 30 times to collect logs serially
# in a real scenario, you wouldn't loop and you'd call different
# bash scripts or commands
for i in range(30):
    try:
        logs = subprocess.run(["bash", "/opt/custom_bash.sh"], capture_output=True, text=True)
        log_lines = logs.stdout
        # debugging
        print(f"log_lines: {log_lines}")
        try:
            # Create a TCP socket
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
                s.connect((TCP_HOST, TCP_PORT))
                s.sendall(log_lines.encode('utf-8'))
        except Exception as e:
            print(f"Error sending logs: {e}")
    except Exception as e:
        print(f"Error collecting logs: {e}")
