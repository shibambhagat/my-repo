// my-repo/index.js
const express = require('express');
const app = express();
// CRITICAL FIX: Ensure application binds to 0.0.0.0 for external access
const PORT = process.env.PORT || 8080; 

// The default route
app.get('/', (req, res) => {
  res.send('It's working!');
});

// CRITICAL FIX: Add the /health endpoint for the Load Balancer Health Check
app.get('/health', (req, res) => {
  // Always return 200 for a healthy instance
  res.status(200).send('OK'); 
});

// CRITICAL FIX: Explicitly bind the server to '0.0.0.0'
app.listen(PORT, '0.0.0.0', () => {
  console.log(`Server running on port ${PORT}`);
});
