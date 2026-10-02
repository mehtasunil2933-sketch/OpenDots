# Deploying OpenDots on Zerops

Three services in one Zerops project:

| Service    | Type                      | Runs                                                                     |
| ---------- | ------------------------- | ------------------------------------------------------------------------ |
| `vol`      | `local-storage:single@1`  | Persistent disk for `app` (SQLite)                                       |
| `app`      | `nodejs@24` (autoscaling) | Web app + API on 4310 (public subdomain), page browser on 127.0.0.1:4311 |
| `computer` | `docker@26.1` (fixed VM)  | OpenBot supervisor on 4312 + one computer per Dot on 41001–41010         |

`app` reaches the supervisor at `http://computer:4312` and each Dot computer at
`http://computer:<port>` over the private project network. Only port 4310 on `app` is public.

## Repo changes for the separate `computer` service

1. `src/server/computer-service.ts`: a published computer port is accepted on the
   supervisor's own host (`computer`), not only on `127.0.0.1`. Local and Compose
   behaviour is unchanged. Covered by `tests/computer.test.ts`.
2. `deployment/computers/remote-supervisor.mjs`: build-time, fail-closed patch to the
   pinned OpenBot supervisor. With `COMPUTER_PORT_POOL` set it publishes each computer on
   the first free port of the pool on `COMPUTER_PUBLISH_IP`, and reports
   `http://$COMPUTER_PUBLIC_HOST:<port>`. Without it the supervisor behaves like upstream.
   Covered by `tests/computer-deployment.test.js`.

## Steps

1. Create the Cloudflare R2 bucket `opendots-backup` and an R2 API token. Both services
   refuse to start empty when R2 is configured but unreachable.
2. Generate four different secrets: `openssl rand -hex 24` (×4).
3. Paste `zerops/import.yaml` into **Zerops → Import project** with every `REPLACE_` value
   filled in. If the import rejects `verticalAutoscaling`, remove it and set the values in the GUI.
4. Copy the `app` subdomain URL into `APP_ORIGIN` in `zerops.yaml`, set `OPENAI_MODEL`,
   commit and push.
5. Connect this repo to **computer** first and deploy, then connect it to **app** and deploy.
   Each service uses the `setup` matching its hostname.

## Gates

`computer` web terminal:

```sh
docker ps --format '{{.Names}}  {{.Status}}'               # od-supervisor Up
wget -qO- http://127.0.0.1:4312/health; echo                # {"status":"ok","docker":true}
docker image ls | grep opendots                             # supervisor + computer images
```

`app` web terminal:

```sh
echo "owner=${#OWNER_TOKEN} browser=${#BROWSER_SECRET} sup=${#COMPUTER_SUPERVISOR_TOKEN} comp=${#COMPUTER_TOKEN}"   # all 48
ss -lntp | grep -E ':4310|:4311'                            # 4310 on 0.0.0.0, 4311 on 127.0.0.1
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:4310/api/state            # 401
curl -s http://computer:4312/health; echo                   # {"status":"ok","docker":true}
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $COMPUTER_SUPERVISOR_TOKEN" http://computer:4312/computers   # 200
mount | grep /mnt/vol; ls -la /mnt/vol/opendots             # opendots.sqlite
rclone lsd r2:                                              # lists opendots-backup
```

Then open the app, sign in with `OWNER_TOKEN`, open a Dot's **Computer** panel, enable it
and choose **Start**. On `computer`:

```sh
docker ps --filter label=openbot.supervisor=true --format '{{.Names}} {{.Ports}}'   # 0.0.0.0:41001->4100/tcp
```

and on `app`: `curl -s http://computer:41001/health; echo` must answer.

Backups: `app` SQLite daily via cron (`r2:opendots-backup/app/`); Dot computer volumes
every 6 hours and on stop (`r2:opendots-backup/computers/`). Conversation history lives
in CopilotKit Intelligence, not in these backups.
