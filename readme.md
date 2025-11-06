# Installing Docker on Linux (Ubuntu)

[https://trash-guides.info/File-and-Folder-Structure/How-to-set-up/Docker/]

## Helpfull Sites

**Servarr Wiki**
[https://wiki.servarr.com/]

**TRaSH Guides**
[https://trash-guides.info/]

## Install Prerequisites

```
sudo apt-get update
sudo apt-get install cron nano jq
```

## Set up Docker's apt repository:

```
sudo apt-get update
sudo apt-get install ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
```

## Install Docker packages:

```
sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

## Verify the installation:

```
sudo docker run hello-world
```

## Post-Installation Steps

To allow non-privileged users to run Docker commands, add your user to the docker group:

```
sudo usermod -aG docker $USER
sudo chown root:docker /var/run/docker.sock
sudo chmod 660 /var/run/docker.sock
newgrp docker
```

## Install Portainer for Web GUI

Create Portainer Compose file
```
nano portainer-compose.yml
```
Paste contents of **portainer-compose.yml** in to editor.
Save file (CTRL+X)

```
docker compose -f portainer-compose.yml -p portainer up -d
```

### Setup Portainer Password

Access Portainer WebUI and create password:
https://<serverip>:9443/

## Install Pullio to Automate Image Updates

[https://hotio.dev/scripts/pullio/]

```
sudo curl -fsSL "https://raw.githubusercontent.com/hotio/pullio/master/pullio.sh" -o /usr/local/bin/pullio
sudo chmod +x /usr/local/bin/pullio
(crontab -l ; echo "0 * * * * /usr/local/bin/pullio > /mnt/docker/logs/pullio.log 2>&1") | sort - | uniq - | crontab - > /dev/null
```

## Build Media Suite

### Create Folders

```
sudo mkdir -p /mnt/docker/traefik/{acme,certificates,config}
sudo mkdir -p /mnt/docker/appdata/{radarr,sonarr,lidarr,readarr,homarr,prowlarr,qbittorrent,plex}
sudo mkdir -p /mnt/docker/appdata/plex/{config,transcode}
sudo mkdir -p /mnt/data/torrents/{movies,tv,music,books}
sudo mkdir -p /mnt/data/media/{movies,tv,music,books}
sudo mkdir -p /mnt/docker/logs
sudo chown 1000:990 -R /mnt
```

### Create Certificates

Create a self-signed certificate. Make sure to change the subject details to match your requirments.
You can replace this with a valid certificate using LetsEncrypt, but that can be complicated.

```
CRT_VALIDITY=7300
CRT_C=AU
CRT_S="Western Australia"
CRT_L=Perth
CRT_OU=HomeLab
CRT_CN=server.domain.tld

TLS_SUBJECT="/C=${CRT_C}/ST=${CRT_S}/L=${CRT_L}/O=${CRT_OU}/CN=${CRT_CN}"

openssl req -x509 -newkey rsa:4096 -keyout /mnt/docker/traefik/certificates/cert.key -out /mnt/docker/traefik/certificates/cert.crt -days $CRT_VALIDITY -nodes -subj "$TLS_SUBJECT"
```

### Create 'traefik' certificate store

```
echo -e "tls:\n\
  stores:\n\
    default:\n\
      defaultCertificate:\n\
        certFile: /etc/traefik/certificates/cert.crt\n\
        keyFile: /etc/traefik/certificates/cert.key\n\
  certificates:\n\
    - certFile: /etc/traefik/certificates/cert.crt\n\
      keyFile: /etc/traefik/certificates/cert.key\n\
      stores:\n\
        - default\n" | tee  /mnt/docker/traefik/config/certificates.yml > /dev/null
```

### Create 'portainer' reverse proxy rules

```
IP_ADDRESS=$(ip -4 addr show $(ip route | grep default | awk '{print $5}') | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
echo -e "http:\n\
  routers:\n\
    docker:\n\
      rule: \"PathPrefix(\`/docker\`)\"\n\
      service: docker-service\n\
      entryPoints:\n\
        - websecure\n\
      middlewares:\n\
        - docker-redirect\n\
        - docker-strip-prefix\n\
  middlewares:\n\
    docker-strip-prefix:\n\
      stripPrefix:\n\
        prefixes:\n\
          - \"/docker\"\n\
    docker-redirect:\n\
      redirectRegex:\n\
        regex: \"^(.*)/docker\$\$\"\n\
        replacement: /docker/\n\
  services:\n\
    docker-service:\n\
      loadBalancer:\n\
       servers:\n\
         - url: \"https://${IP_ADDRESS}:9443\"\n" | tee /mnt/docker/traefik/config/portainer-route.yml > /dev/null
```

### Edit .env File

Edit the .env file to match you needs.
Make sure you update your PLEX Claim Code (be quick as this code only lasts 4 minutes)
[https://plex.tv/claim]

### Upload Composer File to Portainer

1. Access Portainer WebUI [https://<serverip>:9443/]
2. Navigate to "Stacks"
3. Click "Add Stack"
4. Upload "media-suite-compose.yml"
5. Upload ".env" file (make any last minute changes, like your Plex Claim Code) 
6. Click "Deploy the stack"
7. Wait ~5 mins for all containers to be pulled and the services to start

You can monotor the stack from Portainer and view the console logs from each containter.
Fpr the *arr apps, you'll be asked to setup authentication. This is optional, but recommended.

# Access Services

All services are managed by Traefik to simplify routing and access.

* Dashboard (Homarr)
[https://<serverip>/]

* Traefik Proxy (Traefik)
[https://<serverip>/dashboard]

* Docker Admin (Portainer)
[https://<serverip>/docker]
[https://<serverip>:9443] (Backup)

* Media Apps
Radarr [https://<serverip>/movies]
Sonarr [https://<serverip>/tv]
Lidarr [https://<serverip>/music]
Readarr [https://<serverip>/books]
Prowlarr [https://<serverip>/idx]
BitTorrent [https://<serverip>/download]

* Plex Server
[https://<serverip>:8443] (Web UI)
[http://<serverip>:32400] (NAT Port Forward)

# Configure Apps

Configuring all these servers will take time, **TRaSH Guides** [https://trash-guides.info/] is the best place to start.

