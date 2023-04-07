# Mise en place de TypeSense

https://typesense.org/docs/guide/install-typesense.html#deb-package-on-ubuntu-debian

```sh
curl -O https://dl.typesense.org/releases/0.24.1/typesense-server-0.24.1-amd64.deb
apt install ./typesense-server-0.24.1-amd64.deb
```

Dans le fichier de configuration `/etc/typesense/typesense-server.ini` :
- `api-address = 127.0.0.1`
- Récupérer la valeur de `api-key` pour l'utiliser dans la configuration de Zeste de Savoir

Mettre en place la rotation des logs dans le fichier `/etc/logrotate.d/typesense` :
```
/var/log/typesense/typesense*.log {
        rotate 52
        compress
        size 2M
        missingok
        notifempty
        delaycompress
}
```
