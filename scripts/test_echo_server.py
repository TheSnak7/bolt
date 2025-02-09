# AI generated script to test the echo server

import asyncio
import time
import statistics
import argparse
from datetime import datetime

class Metrics:
    def __init__(self):
        self.connection_times = []
        self.round_trip_times = []
        self.failed_connections = 0
        self.failed_messages = 0
        self.total_messages = 0
        self.start_time = None
        self.end_time = None

    def print_results(self):
        duration = self.end_time - self.start_time
        success_rate = ((self.total_messages - self.failed_messages) / self.total_messages * 100 
                       if self.total_messages > 0 else 0)
        
        print("\n=== Echo Server Stress Test Results ===")
        print(f"Duration: {duration:.2f} seconds")
        print(f"\nConnections:")
        print(f"- Failed Connections: {self.failed_connections}")
        print(f"- Average Connection Time: {statistics.mean(self.connection_times):.3f}s")
        print(f"- Connection Time (95th percentile): {statistics.quantiles(self.connection_times, n=20)[-1]:.3f}s")
        
        print(f"\nMessages:")
        print(f"- Total Messages: {self.total_messages}")
        print(f"- Failed Messages: {self.failed_messages}")
        print(f"- Success Rate: {success_rate:.1f}%")
        
        if self.round_trip_times:
            print(f"\nLatency:")
            print(f"- Average RTT: {statistics.mean(self.round_trip_times)*1000:.2f}ms")
            print(f"- Median RTT: {statistics.median(self.round_trip_times)*1000:.2f}ms")
            print(f"- 95th percentile RTT: {statistics.quantiles(self.round_trip_times, n=20)[-1]*1000:.2f}ms")
            print(f"- Min RTT: {min(self.round_trip_times)*1000:.2f}ms")
            print(f"- Max RTT: {max(self.round_trip_times)*1000:.2f}ms")

async def echo_client(host, port, messages_per_client, message_size, metrics):
    try:
        conn_start = time.time()
        reader, writer = await asyncio.open_connection(host, port)
        conn_time = time.time() - conn_start
        metrics.connection_times.append(conn_time)
        
        message = 'X' * message_size
        
        for _ in range(messages_per_client):
            metrics.total_messages += 1
            try:
                # Send message and measure round trip time
                start_time = time.time()
                writer.write(message.encode())
                await writer.drain()
                
                response = await reader.read(message_size)
                rtt = time.time() - start_time
                
                if response.decode() != message:
                    metrics.failed_messages += 1
                else:
                    metrics.round_trip_times.append(rtt)
                    
            except Exception as e:
                metrics.failed_messages += 1
                print(f"Error sending/receiving message: {e}")
                
        writer.close()
        await writer.wait_closed()
        
    except Exception as e:
        metrics.failed_connections += 1
        print(f"Connection failed: {e}")

async def run_stress_test(host, port, num_clients, messages_per_client, message_size):
    metrics = Metrics()
    metrics.start_time = time.time()
    
    # Create multiple clients
    clients = [echo_client(host, port, messages_per_client, message_size, metrics) 
              for _ in range(num_clients)]
    
    # Run all clients concurrently
    await asyncio.gather(*clients)
    
    metrics.end_time = time.time()
    metrics.print_results()

def main():
    parser = argparse.ArgumentParser(description='Echo Server Stress Test')
    parser.add_argument('--host', default='127.0.0.1', help='Server host')
    parser.add_argument('--port', type=int, default=3000, help='Server port')
    parser.add_argument('--clients', type=int, default=100, help='Number of concurrent clients')
    parser.add_argument('--messages', type=int, default=10, help='Messages per client')
    parser.add_argument('--size', type=int, default=100, help='Message size in bytes')
    
    args = parser.parse_args()
    
    print(f"Starting stress test with {args.clients} clients, "
          f"{args.messages} messages per client, "
          f"{args.size} bytes per message")
    
    asyncio.run(run_stress_test(
        args.host, 
        args.port, 
        args.clients, 
        args.messages, 
        args.size
    ))

if __name__ == "__main__":
    main() 