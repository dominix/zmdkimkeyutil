# zmdkimkeyutil
zimbra zmdkimkeyutil version that import key so you can use the same key on your spare server
to import a key, do a zmdkimkeyutil -q -d domain.ex on original server
put key in /tmp/privkey, put publickey in /tmp/public and note selector
zmdkimkeyutil.import -i -d domain.ex  -s <selector> -k /tmp/privkey -p /tmp/public

use at your own risk, 
this script is a hack, it dosn't verifiy if key or public signature is valid.
