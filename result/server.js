// Capstone 1 - The Voting App
// Result Service - Node.js Express with Server-Sent Events
// Reads votes from PostgreSQL and pushes real-time updates

const express = require('express');
const { Pool } = require('pg');
const http = require('http');
const { Server } = require('socket.io');
const path = require('path');

const app = express();
const server = http.createServer(app);
const io = new Server(server, {
  cors: {
    origin: "*",
    methods: ["GET", "POST"]
  }
});

// Configuration from environment
const config = {
  db: {
    host: process.env.DB_HOST || 'db',
    port: parseInt(process.env.DB_PORT || '5432'),
    database: process.env.DB_NAME || 'postgres',
    user: process.env.DB_USER || 'postgres',
    password: process.env.DB_PASSWORD || '',
    passwordFile: process.env.DB_PASSWORD_FILE || '/run/secrets/db_password',
    max: 10,
    idleTimeoutMillis: 30000,
    connectionTimeoutMillis: 5000,
  },
  port: parseInt(process.env.PORT || '8080'),
  pollInterval: parseInt(process.env.POLL_INTERVAL || '1000'), // 1 second
};

// Read password from file (Docker secret)
const fs = require('fs');
if (fs.existsSync(config.db.passwordFile)) {
  config.db.password = fs.readFileSync(config.db.passwordFile, 'utf8').trim();
}

// PostgreSQL connection pool
const pool = new Pool(config.db);

pool.on('error', (err) => {
  console.error('Unexpected error on idle client', err);
  process.exit(-1);
});

// Serve static files
app.use(express.static(path.join(__dirname, 'public')));

// Health check endpoint
app.get('/health', async (req, res) => {
  try {
    const client = await pool.connect();
    await client.query('SELECT 1');
    client.release();
    res.json({ status: 'healthy', database: 'connected' });
  } catch (err) {
    console.error('Health check failed:', err);
    res.status(503).json({ status: 'unhealthy', database: 'disconnected', error: err.message });
  }
});

// Get current vote counts
app.get('/api/votes', async (req, res) => {
  try {
    const result = await pool.query(`
      SELECT vote, COUNT(*) as count 
      FROM votes 
      GROUP BY vote
    `);
    
    const counts = { Cats: 0, Dogs: 0 };
    result.rows.forEach(row => {
      counts[row.vote] = parseInt(row.count);
    });
    
    res.json(counts);
  } catch (err) {
    console.error('Error fetching votes:', err);
    res.status(500).json({ error: 'Failed to fetch vote counts' });
  }
});

// Get recent votes (for initial load)
app.get('/api/votes/recent', async (req, res) => {
  try {
    const limit = parseInt(req.query.limit || '50');
    const result = await pool.query(`
      SELECT voter_id, vote, created_at 
      FROM votes 
      ORDER BY created_at DESC 
      LIMIT $1
    `, [limit]);
    
    res.json(result.rows.reverse()); // Oldest first for display
  } catch (err) {
    console.error('Error fetching recent votes:', err);
    res.status(500).json({ error: 'Failed to fetch recent votes' });
  }
});

// Server-Sent Events endpoint for real-time updates
app.get('/events', async (req, res) => {
  // Set SSE headers
  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  res.setHeader('X-Accel-Buffering', 'no'); // Disable nginx buffering
  res.flushHeaders();

  // Send initial data
  try {
    const result = await pool.query(`
      SELECT vote, COUNT(*) as count 
      FROM votes 
      GROUP BY vote
    `);
    
    const counts = { Cats: 0, Dogs: 0 };
    result.rows.forEach(row => {
      counts[row.vote] = parseInt(row.count);
    });
    
    res.write(`data: ${JSON.stringify({ type: 'init', data: counts })}\n\n`);
  } catch (err) {
    console.error('Error sending initial data:', err);
  }

  // Track connected clients
  const clientId = Date.now();
  console.log(`SSE client connected: ${clientId}`);

  // Heartbeat to keep connection alive
  const heartbeat = setInterval(() => {
    res.write(': heartbeat\n\n');
  }, 30000);

  // Handle client disconnect
  req.on('close', () => {
    clearInterval(heartbeat);
    console.log(`SSE client disconnected: ${clientId}`);
  });
});

// Socket.io for alternative real-time (WebSocket)
io.on('connection', (socket) => {
  console.log('WebSocket client connected:', socket.id);
  
  // Send initial counts
  pool.query(`
    SELECT vote, COUNT(*) as count 
    FROM votes 
    GROUP BY vote
  `).then(result => {
    const counts = { Cats: 0, Dogs: 0 };
    result.rows.forEach(row => {
      counts[row.vote] = parseInt(row.count);
    });
    socket.emit('voteUpdate', counts);
  }).catch(err => {
    console.error('Error sending initial counts:', err);
  });

  socket.on('disconnect', () => {
    console.log('WebSocket client disconnected:', socket.id);
  });
});

// Broadcast vote updates to all connected clients
async function broadcastVoteUpdate() {
  try {
    const result = await pool.query(`
      SELECT vote, COUNT(*) as count 
      FROM votes 
      GROUP BY vote
    `);
    
    const counts = { Cats: 0, Dogs: 0 };
    result.rows.forEach(row => {
      counts[row.vote] = parseInt(row.count);
    });
    
    // Send via SSE (handled by polling in client)
    // Send via WebSocket
    io.emit('voteUpdate', counts);
    
    return counts;
  } catch (err) {
    console.error('Error broadcasting vote update:', err);
    return null;
  }
}

// Poll database for changes and broadcast
let lastCounts = { Cats: 0, Dogs: 0 };
let pollTimer = null;

async function pollForChanges() {
  try {
    const result = await pool.query(`
      SELECT vote, COUNT(*) as count 
      FROM votes 
      GROUP BY vote
    `);
    
    const counts = { Cats: 0, Dogs: 0 };
    result.rows.forEach(row => {
      counts[row.vote] = parseInt(row.count);
    });
    
    // Check if counts changed
    if (counts.Cats !== lastCounts.Cats || counts.Dogs !== lastCounts.Dogs) {
      lastCounts = counts;
      
      // Broadcast to SSE clients (they poll the /events endpoint)
      // Broadcast to WebSocket clients
      io.emit('voteUpdate', counts);
      console.log('Vote counts updated:', counts);
    }
  } catch (err) {
    console.error('Polling error:', err);
  }
}

// Start polling
function startPolling() {
  if (pollTimer) clearInterval(pollTimer);
  pollTimer = setInterval(pollForChanges, config.pollInterval);
  console.log(`Started polling for vote changes every ${config.pollInterval}ms`);
}

// Graceful shutdown
async function shutdown() {
  console.log('Shutting down...');
  if (pollTimer) clearInterval(pollTimer);
  await pool.end();
  server.close(() => {
    console.log('Server closed');
    process.exit(0);
  });
}

process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);

// Start server
server.listen(config.port, '0.0.0.0', () => {
  console.log(`Result service listening on port ${config.port}`);
  startPolling();
  
  // Get initial counts
  pollForChanges().then(() => {
    console.log('Initial vote counts loaded');
  });
});