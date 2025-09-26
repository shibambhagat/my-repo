// my-repo/index.js
const express = require('express');
const app = express();
const PORT = process.env.PORT || 8080; // Correctly setting the port

app.get("/", (req, res) => {
    // Ensuring a 200 OK response for the Health Check Path (/)
    res.status(200).send("Hi Cloudies");
});

// CRITICAL FIX: Explicitly bind the server to 0.0.0.0
app.listen(PORT, '0.0.0.0', () => { 
    console.log(`Server running on port ${PORT}`);
});
