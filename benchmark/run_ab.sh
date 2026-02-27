#!/bin/bash

# Check if server is running
curl -s http://localhost:8080 > /dev/null
if [ $? -ne 0 ]; then
    echo "Error: Server is not running on http://localhost:8080"
    echo "Please start the server first (e.g., 'zig build run-blog')"
    exit 1
fi

echo "========================================================"
echo "🚀 Starting Apache Bench (ab) Benchmark"
echo "========================================================"

# 1. Basic GET / (Hello World / Home)
echo ""
echo "1. Benchmarking GET / (Home Page)"
echo "   - 10,000 requests"
echo "   - 100 concurrent connections"
ab -n 10000 -c 100 -k http://localhost:8080/

# 2. GET /api/posts (JSON List)
echo ""
echo "2. Benchmarking GET /api/posts (JSON List)"
echo "   - 10,000 requests"
echo "   - 100 concurrent connections"
ab -n 10000 -c 100 -k http://localhost:8080/api/posts

# 3. POST /api/users (JSON Body)
# Create a temporary file for POST data
echo '{"username":"bench_user","email":"bench@example.com","password":"password123"}' > post_data.json

echo ""
echo "3. Benchmarking POST /api/users (JSON Creation)"
echo "   - 5,000 requests"
echo "   - 50 concurrent connections"
ab -n 5000 -c 50 -k -p post_data.json -T application/json http://localhost:8080/api/users

# Cleanup
rm post_data.json

echo ""
echo "✅ Benchmark Complete"
