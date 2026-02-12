const crypto = require('crypto');
const Database = require('better-sqlite3');
const db = new Database('/appdata/db.sqlite');
const rid = () => crypto.randomBytes(12).toString('hex');

const board = db.prepare('SELECT id FROM board WHERE name = ?').get('Infrastructure');
if (!board) { console.log('Infrastructure board not found'); process.exit(0); }

const layout = db.prepare('SELECT id FROM layout WHERE board_id = ?').get(board.id);
if (!layout) { console.log('No layout for Infrastructure board'); process.exit(0); }

const count = db.prepare('SELECT COUNT(*) as c FROM item WHERE board_id = ?').get(board.id);
if (count.c > 0) {
  console.log('Infrastructure board already populated');
  db.close();
  process.exit(0);
}

const apps = db.prepare('SELECT id, name FROM app').all();
const appMap = {};
apps.forEach(a => appMap[a.name] = a.id);

const infraApps = ['Authentik', 'Traefik'];
const sectionId = rid();

db.prepare('INSERT INTO section (id, board_id, kind, x_offset, y_offset, name) VALUES (?, ?, ?, ?, ?, ?)').run(sectionId, board.id, 'category', 0, 0, 'Infrastructure');
db.prepare('INSERT INTO section_layout (section_id, layout_id, x_offset, y_offset, width, height) VALUES (?, ?, ?, ?, ?, ?)').run(sectionId, layout.id, 0, 0, 12, 1);

let col = 0, row = 0;
for (const appName of infraApps) {
  if (!appMap[appName]) { console.log('App not found: ' + appName); continue; }
  const itemId = rid();
  const options = JSON.stringify({ json: { appId: appMap[appName] } });
  const advOpts = JSON.stringify({ json: {} });
  db.prepare('INSERT INTO item (id, board_id, kind, options, advanced_options) VALUES (?, ?, ?, ?, ?)').run(itemId, board.id, 'app', options, advOpts);
  db.prepare('INSERT INTO item_layout (item_id, section_id, layout_id, x_offset, y_offset, width, height) VALUES (?, ?, ?, ?, ?, ?, ?)').run(itemId, sectionId, layout.id, col * 2, row, 2, 1);
  col++;
  if (col >= 6) { col = 0; row++; }
}

// Grant credentials-admin group access (local admin)
try {
  const adminGroup = db.prepare('SELECT id FROM [group] WHERE name = ?').get('credentials-admin');
  if (adminGroup) {
    const existing = db.prepare('SELECT board_id FROM boardGroupPermission WHERE board_id = ? AND group_id = ?').get(board.id, adminGroup.id);
    if (!existing) {
      db.prepare('INSERT INTO boardGroupPermission (board_id, group_id, permission) VALUES (?, ?, ?)').run(board.id, adminGroup.id, 'board-view-all');
      console.log('Board permission set for credentials-admin group');
    }
  }
} catch (e) {
  console.log('WARN: Could not set group permission: ' + e.message);
}

// Grant any existing OIDC users access (admin users logged in via Authentik)
try {
  const oidcUsers = db.prepare('SELECT id FROM user WHERE provider = ?').all('oidc');
  for (const u of oidcUsers) {
    const existing = db.prepare('SELECT board_id FROM boardUserPermission WHERE board_id = ? AND user_id = ?').get(board.id, u.id);
    if (!existing) {
      db.prepare('INSERT INTO boardUserPermission (board_id, user_id, permission) VALUES (?, ?, ?)').run(board.id, u.id, 'board-view-all');
      console.log('Board permission set for OIDC user ' + u.id);
    }
  }
} catch (e) {
  console.log('WARN: Could not set user permissions: ' + e.message);
}

console.log('Infrastructure board populated');
db.close();
