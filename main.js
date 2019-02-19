const electron = require('electron');

function createWindow() {
  let win = new BrowserWindow({width: 800, height: 600});

  win.loadFile('index.html');
}

app.on('ready', createWindow);