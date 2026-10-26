# Capstone 1 - The Voting App
# Vote Service - Python Flask Web Application
# Accepts votes and pushes them to Redis queue

import os
import json
import uuid
import logging
from flask import Flask, request, render_template_string, jsonify
import redis

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s %(levelname)s %(name)s %(message)s'
)
logger = logging.getLogger(__name__)

app = Flask(__name__)

# Configuration from environment
REDIS_HOST = os.getenv('REDIS_HOST', 'redis')
REDIS_PORT = int(os.getenv('REDIS_PORT', 6379))

# Redis connection with retry logic
def get_redis_connection():
    """Create Redis connection with error handling"""
    try:
        client = redis.Redis(
            host=REDIS_HOST,
            port=REDIS_PORT,
            decode_responses=True,
            socket_connect_timeout=5,
            socket_timeout=5,
            retry_on_timeout=True,
            health_check_interval=30
        )
        client.ping()
        logger.info(f"Connected to Redis at {REDIS_HOST}:{REDIS_PORT}")
        return client
    except redis.ConnectionError as e:
        logger.error(f"Failed to connect to Redis: {e}")
        raise

# Global Redis client (initialized on startup)
redis_client = None

def init_redis():
    """Initialize Redis connection"""
    global redis_client
    redis_client = get_redis_connection()

# HTML template for the voting page
VOTE_TEMPLATE = """
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>The Voting App - Cast Your Vote</title>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); min-height: 100vh; display: flex; align-items: center; justify-content: center; padding: 20px; }
        .container { background: white; border-radius: 16px; box-shadow: 0 20px 60px rgba(0,0,0,0.3); padding: 40px; max-width: 400px; width: 100%; }
        h1 { color: #333; text-align: center; margin-bottom: 10px; font-size: 28px; }
        .subtitle { text-align: center; color: #666; margin-bottom: 30px; }
        .options { display: flex; flex-direction: column; gap: 15px; }
        .vote-btn { padding: 20px; border: none; border-radius: 12px; font-size: 18px; font-weight: 600; cursor: pointer; transition: all 0.2s; display: flex; align-items: center; justify-content: center; gap: 12px; }
        .vote-btn:active { transform: scale(0.98); }
        .vote-btn:disabled { opacity: 0.6; cursor: not-allowed; }
        .btn-cats { background: linear-gradient(135deg, #ff6b6b 0%, #ee5a5a 100%); color: white; }
        .btn-cats:hover:not(:disabled) { background: linear-gradient(135deg, #ff5252 0%, #e53935 100%); box-shadow: 0 8px 25px rgba(255,107,107,0.4); }
        .btn-dogs { background: linear-gradient(135deg, #4ecdc4 0%, #26a69a 100%); color: white; }
        .btn-dogs:hover:not(:disabled) { background: linear-gradient(135deg, #26d5ce 0%, #009688 100%); box-shadow: 0 8px 25px rgba(78,205,196,0.4); }
        .icon { font-size: 24px; }
        .message { text-align: center; margin-top: 20px; padding: 15px; border-radius: 8px; display: none; }
        .message.success { background: #e8f5e9; color: #2e7d32; display: block; }
        .message.error { background: #ffebee; color: #c62828; display: block; }
        .footer { text-align: center; margin-top: 30px; color: #999; font-size: 14px; }
        .footer a { color: #667eea; text-decoration: none; }
        .footer a:hover { text-decoration: underline; }
    </style>
</head>
<body>
    <div class="container">
        <h1>🗳️ The Voting App</h1>
        <p class="subtitle">Which do you prefer?</p>
        
        <div class="options">
            <button class="vote-btn btn-cats" onclick="vote('Cats')" id="btn-cats">
                <span class="icon">🐱</span> Cats
            </button>
            <button class="vote-btn btn-dogs" onclick="vote('Dogs')" id="btn-dogs">
                <span class="icon">🐶</span> Dogs
            </button>
        </div>
        
        <div class="message success" id="success-msg">Thanks for voting! Your vote has been counted.</div>
        <div class="message error" id="error-msg">Something went wrong. Please try again.</div>
        
        <div class="footer">
            <a href="http://localhost:5001" target="_blank">View Results →</a>
        </div>
    </div>

    <script>
        function vote(option) {
            const buttons = document.querySelectorAll('.vote-btn');
            const successMsg = document.getElementById('success-msg');
            const errorMsg = document.getElementById('error-msg');
            
            // Disable buttons and hide messages
            buttons.forEach(btn => btn.disabled = true);
            successMsg.style.display = 'none';
            errorMsg.style.display = 'none';
            
            fetch('/vote', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ vote: option })
            })
            .then(response => response.json())
            .then(data => {
                if (data.success) {
                    successMsg.style.display = 'block';
                } else {
                    errorMsg.textContent = data.error || 'Vote failed';
                    errorMsg.style.display = 'block';
                }
            })
            .catch(() => {
                errorMsg.style.display = 'block';
            })
            .finally(() => {
                setTimeout(() => {
                    buttons.forEach(btn => btn.disabled = false);
                }, 2000);
            });
        }
    </script>
</body>
</html>
"""

@app.route('/', methods=['GET'])
def index():
    """Serve the voting page"""
    return render_template_string(VOTE_TEMPLATE)

@app.route('/vote', methods=['POST'])
def vote():
    """Handle vote submission"""
    try:
        data = request.get_json()
        if not data or 'vote' not in data:
            return jsonify({'success': False, 'error': 'Invalid request'}), 400
        
        vote_value = data['vote']
        if vote_value not in ['Cats', 'Dogs']:
            return jsonify({'success': False, 'error': 'Invalid vote option'}), 400
        
        # Generate unique voter ID (in production, use proper session/cookie)
        voter_id = str(uuid.uuid4())
        
        # Push vote to Redis queue (list) - use camelCase for C# deserialization
        vote_data = json.dumps({
            'voterId': voter_id,
            'vote': vote_value
        })
        
        redis_client.lpush('votes', vote_data)
        logger.info(f"Vote queued: {vote_value} from {voter_id}")
        
        return jsonify({'success': True})
    
    except redis.ConnectionError:
        logger.error("Redis connection error during vote")
        return jsonify({'success': False, 'error': 'Service temporarily unavailable'}), 503
    except Exception as e:
        logger.error(f"Error processing vote: {e}")
        return jsonify({'success': False, 'error': 'Internal server error'}), 500

@app.route('/health', methods=['GET'])
def health():
    """Health check endpoint"""
    try:
        redis_client.ping()
        return jsonify({'status': 'healthy', 'redis': 'connected'}), 200
    except Exception:
        return jsonify({'status': 'unhealthy', 'redis': 'disconnected'}), 503

# Initialize Redis on module import (for gunicorn)
init_redis()

if __name__ == '__main__':
    init_redis()
    app.run(host='0.0.0.0', port=8080, debug=False)