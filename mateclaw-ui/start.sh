#!/bin/bash
echo "🚀 Coze Chat Full Startup Script"
echo "=========================="

if [ ! -d "node_modules" ]; then
    echo "📦 Installing dependencies..."
    npm install
fi

echo "🎯 Starting development server..."
echo "Access URL: http://localhost:5173"
echo ""
nohup npm run dev -- --host 0.0.0.0 > "logs/mate-ui.log" 2>&1 &
