const express = require('express');
const app = express();
const PORT = process.env.PORT || 8080;

app.get('/', (req, res) => {
  res.send('Hellooo Cloudiess'); // Ensure you change this text for testing!
});

// CRITICAL FIX: Explicitly bind to '0.0.0.0' for external access
app.listen(PORT, '0.0.0.0', () => console.log(`Server running on port ${PORT}`));
