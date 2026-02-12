const crypto = require('crypto');
const bcrypt = require('bcrypt');
const Database = require('better-sqlite3');
const db = new Database('/appdata/db.sqlite');
const user = db.prepare('SELECT id FROM user LIMIT 1').get();
if (!user) { process.exit(1); }
const randomToken = crypto.randomBytes(32).toString('hex');
const salt = bcrypt.genSaltSync(10);
const hashedKey = bcrypt.hashSync(randomToken, salt);
const id = crypto.randomBytes(12).toString('hex');
db.prepare('INSERT INTO apiKey (id, api_key, salt, user_id) VALUES (?, ?, ?, ?)').run(id, hashedKey, salt, user.id);
console.log(id + '.' + randomToken);
db.close();
