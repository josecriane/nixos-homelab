const crypto = require('crypto');
const Database = require('better-sqlite3');
const db = new Database('/appdata/db.sqlite');
const rid = () => crypto.randomBytes(12).toString('hex');

// Make Homelab board public (but not Infrastructure board)
db.prepare('UPDATE board SET is_public = 1 WHERE name != ?').run('Infrastructure');

// Get the board and layout
const board = db.prepare('SELECT id FROM board LIMIT 1').get();
if (!board) { console.log('No board found'); process.exit(0); }

// Set as home board for ALL users
db.prepare('UPDATE user SET home_board_id = ? WHERE home_board_id IS NULL').run(board.id);

// Set as default home board in server settings (for anonymous access)
db.prepare("UPDATE serverSetting SET value = json_set(value, '$.json.homeBoardId', ?) WHERE setting_key = 'board'").run(board.id);

// Check if board already has items
const existingItems = db.prepare('SELECT COUNT(*) as c FROM item WHERE board_id = ?').get(board.id);
if (existingItems.c > 0) {
  console.log('Board already has ' + existingItems.c + ' items, skipping populate');
  db.close();
  process.exit(0);
}

const layout = db.prepare('SELECT id FROM layout WHERE board_id = ?').get(board.id);
if (!layout) { console.log('No layout found'); process.exit(0); }

// Get all apps
const apps = db.prepare('SELECT id, name FROM app').all();
const appMap = {};
apps.forEach(a => appMap[a.name] = a.id);

// Get integrations for linking
const integrations = db.prepare('SELECT id, name FROM integration').all();
const intMap = {};
integrations.forEach(i => intMap[i.name] = i.id);

// Define sections with their apps
const sections = [
  { name: 'Media & Entertainment', apps: ['Jellyfin', 'Jellyseerr', 'Immich'] },
  { name: 'Media Management', apps: ['Sonarr', 'Sonarr ES', 'Radarr', 'Radarr ES', 'Lidarr', 'Prowlarr', 'Bazarr', 'qBittorrent', 'Bookshelf', 'Kavita'] },
  { name: 'Cloud & Storage', apps: ['Nextcloud', 'Syncthing', 'Vaultwarden'] },
  { name: 'Knowledge', apps: ['Kiwix'] },
  { name: 'Monitoring', apps: ['Grafana', 'Prometheus', 'Alertmanager', 'Uptime Kuma'] },
  { name: 'Infrastructure', apps: ['Authentik'] },
];

// Delete old empty section
db.prepare('DELETE FROM section_layout WHERE section_id IN (SELECT id FROM section WHERE board_id = ?)').run(board.id);
db.prepare('DELETE FROM section WHERE board_id = ?').run(board.id);

let sectionY = 0;
const insertSection = db.prepare('INSERT INTO section (id, board_id, kind, x_offset, y_offset, name) VALUES (?, ?, ?, ?, ?, ?)');
const insertSectionLayout = db.prepare('INSERT INTO section_layout (section_id, layout_id, x_offset, y_offset, width, height) VALUES (?, ?, ?, ?, ?, ?)');
const insertItem = db.prepare('INSERT INTO item (id, board_id, kind, options, advanced_options) VALUES (?, ?, ?, ?, ?)');
const insertItemLayout = db.prepare('INSERT INTO item_layout (item_id, section_id, layout_id, x_offset, y_offset, width, height) VALUES (?, ?, ?, ?, ?, ?, ?)');
const insertIntItem = db.prepare('INSERT OR IGNORE INTO integration_item (integration_id, item_id) VALUES (?, ?)');

for (const sec of sections) {
  const sectionId = rid();
  const rows = Math.ceil(sec.apps.length / 6);
  const sectionHeight = rows;

  insertSection.run(sectionId, board.id, 'category', 0, sectionY, sec.name);
  insertSectionLayout.run(sectionId, layout.id, 0, sectionY, 12, sectionHeight);

  let col = 0, row = 0;
  for (const appName of sec.apps) {
    if (!appMap[appName]) continue;
    const itemId = rid();
    // Drizzle ORM uses {json: ...} wrapper for JSON TEXT columns
    const options = JSON.stringify({ json: { appId: appMap[appName] } });
    const advOpts = JSON.stringify({ json: {} });
    insertItem.run(itemId, board.id, 'app', options, advOpts);
    insertItemLayout.run(itemId, sectionId, layout.id, col * 2, row, 2, 1);

    // Link integrations to matching items
    if (intMap[appName]) {
      insertIntItem.run(intMap[appName], itemId);
    }

    col++;
    if (col >= 6) { col = 0; row++; }
  }
  sectionY += sectionHeight;
}

console.log('Board populated with ' + apps.length + ' apps in ' + sections.length + ' sections');
db.close();
