# tgvkbot (fork)

Fork of [Kylmakalle/tgvkbot](https://github.com/Kylmakalle/tgvkbot) at upstream `0cc387b`, carrying three patches so the bot can be deployed in a Kubernetes cluster behind a proxy. `requirements.txt` is deliberately unchanged from upstream, so rebasing stays cheap.

Replay these ten on every rebase:

1. **Proxy support** (`bot.py`, `config.py`) - upstream has none: `aiohttp.ClientSession` is built without `trust_env` and `Bot()` without `proxy=`, so `HTTP_PROXY`/`HTTPS_PROXY` were ignored. `bot.py` now defaults `trust_env=True` on `ClientSession.__init__`, which also covers the sessions `aiovk.drivers` creates internally, and `config.py` exposes `PROXY_URL` which is passed to `Bot()`.
2. **Non-root, read-only-capable image** (`Dockerfile`) - dependencies install to `/opt/deps` instead of `/root/.local` (mode 0700, unreadable to any other user), `makemigrations` runs at build time instead of at container start so the root filesystem can be mounted read-only, the app lives in `/app`, and the container runs as uid 10001. Only `/tmp` needs to be writable at runtime, for attachment staging.

   Migrations are committed under `data/migrations/` and the container only runs `migrate`. They used to be generated at build time, which works on an empty database but breaks on any model change: each image produced its own `0001_initial`, the database already had that name recorded as applied, so the new fields were silently skipped and the app crash-looped on a missing column.

   The builder stage is `python:3.6` rather than `python:3.6-slim` plus `apt-get install gcc`. Upstream pinned a `snapshot.debian.org` archive so that apt call could resolve, but that host returns 503/504 often enough to break builds outright; the full image already ships gcc 10.2.1 with the same Python 3.6.15, so the apt step and the snapshot pin are both gone. The runtime stage is still `python:3.6-slim` and the shipped image is unchanged.
3. **Polling failures are fatal** (`telegram.py`) - upstream calls `executor.start_polling(dp)`, which creates the polling task and then calls `loop.run_forever()`. When a `getUpdates` call raises (a timeout or a reset connection, routine behind an unstable proxy) the polling task dies but the loop keeps running, so the process stays alive and healthy-looking while the bot is deaf. The replacement stops the loop when the polling task finishes and re-raises its exception, so the container exits non-zero and the orchestrator restarts it. This also drops `executor`'s `_startup`, whose only action was an un-retried `getMe` that killed the container outright when the proxy dropped it.

4. **Separate token for photo uploads** (`telegram.py`, `config.py`) - the Marusia token (`client_id=6463690`) grants `messages` but not `photos`, so `photos.getMessagesUploadServer` fails with error 15 subcode 1133 and no photo can be sent to VK. When `VK_PHOTO_TOKEN` is set, `upload_attachment` uses it for `photos.*` calls only; the message itself is still sent with the main token. Unset, it falls back to the main token and behaves as upstream. Obtain the extra token from VFeed (`client_id=4083558`), which holds `photos`.

5. **`messages.getDialogs` replaced** (`telegram.py`) - VK removed that method; it now returns error 3 "Unknown method passed", which broke `/dialogs` and, more importantly, `handle_join`, the picker that binds a Telegram group to a VK dialog. `get_dialogs` now calls `messages.getConversations` and reads `item["conversation"]["peer"]`, keeping the same `order` shape so the rest of the function is unchanged. Note `search_dialogs` still calls `messages.searchDialogs`, which is likely removed too; `/search` is untouched.

6. **Photo uploads need an image filename** (`telegram.py`) - `upload_attachment` derived the multipart filename from `wget.detect_filename`, which falls back to `tgvkbot.document`. VK's photo upload server silently rejects a file whose name has no image extension: it returns `photo: "[]"`, and the following `photos.saveMessagesPhoto` then fails with error 100 `photo is undefined`. Verified directly against the upload server - the same bytes upload fine as `photo.jpg` and are rejected as `tgvkbot.document`; the part's content type makes no difference. Photos are now named `photo.jpg`, and stickers `photo.png` since they are converted to PNG first.

7. **Delivery confirmation and a visible VK auth failure** (`telegram.py`, `vk_messages.py`) - upstream is silent on success and only speaks up on failure, so a message that never reached VK looked identical to one that did. `vk_sender` now reacts to the Telegram message with a thumbs-up on its success path, which covers text, photos, documents and voice in one place. `setMessageReaction` is Bot API 7.0 and far newer than aiogram 1.2.2, but `Bot.request()` takes a raw method name so no library change is needed. Separately, when the long-poll loop hits `VkAuthError` it disables polling permanently; it now also messages the owner, because otherwise the bridge goes quiet with the pod still reporting healthy. It deliberately does not exit the process: the Telegram side is how the owner re-authorizes, so killing it would make recovery impossible.

8. **Stop swallowing VK API errors** (`vk_messages.py`) - the long-poll loop ended with `except VkAPIError: pass`, so any VK API failure while processing an incoming message discarded that message with no log line, no traceback and no change in pod health. Debugging a "messages stopped arriving" report against that is guesswork. It now logs the exception and keeps polling, which is the same recovery with the failure made visible.

9. **Survive proxy blips and resume where the long-poll left off** (`telegram.py`, `vk_messages.py`, `data/models.py`) - patch 3 made a dead Telegram polling task exit the process so the orchestrator would restart it. Behind a flaky proxy that fires roughly hourly, and a restart is not free: the VK long-poll asks `messages.getLongPollServer` for a fresh `ts`, so every VK message that arrived while the container was down is skipped forever. Telegram polling now retries in place on `TimeoutError`, `NetworkError` and `aiohttp.ClientError` instead of exiting, and anything else still ends the process. `VkUser` gains `last_ts`, saved after each batch and restored on startup, so the long-poll resumes from the last processed event. A `ts` that VK considers too old is answered with `failed: 1` and a fresh cursor, so a long outage degrades to the old behaviour rather than breaking.

10. **CI** (`.github/workflows/`) - publishes to GHCR with SHA-pinned actions, replacing the unpinned `elgohr/Publish-Docker-Github-Action@master` that held registry push credentials.

Upstream's own README follows.

---

# tgvkbot
Общайтесь в VK через Telegram бота.

- Бот от разработчика - [@tgvkbot](https://t.me/tgvkbot)

- Канал - [@tg_vk](https://t.me/tg_vk)

- Чат - https://t.me/joinchat/BZq6jwxeTh04qBzilM5x3g


# Простая Установка (Ubuntu)
```bash
git clone https://github.com/Kylmakalle/tgvkbot
cd tgvkbot
./install.sh

Токен Telegram бота: 123456789:AAABBBCCCDDDEEEFFFGGGHHHIIIJJJKKKLL
VK APP ID (можно оставить пустым):
```

Далее потребуется ввести пароль от `sudo` пользователя и Telegram-token, остальные переменные необязательны.

_Установщик поставит Docker и docker-compose, настроит переменные окружения и запустит контейнер для обновлений, а затем поднимет бота с его базой данных._

### Обновление
Бот автоматически обновляется через образ на [dockerhub](https://hub.docker.com/r/kylmakalle/tgvkbot/tags?page=1&ordering=last_updated), где на всякий случай фиксируются версии каждого коммита. 

Стандартный установщик поднимает [watchtower](https://containrrr.dev/watchtower), который раз в час проверяет обновления.


### Ограничение пользователей
Если по каким-то причинам хочется чтобы ботом пользовались исключительно определенные пользователи, то это можно сделать изменив файл конфигурации.
Потребуется прописать параметр в таком виде, где числа - Telegram ID пользователей через запятую.

`ALLOWED_USER_IDS=12345678,001238091`

ID можно узнать командой `/id` в боте или через других ботов/софт.


### Кастомизация
С недавнего времени бот поднимается с помощью готового docker образа. Если нужно сделать какую-то специфичную правку, то бота можно поднять через отдельный файл командой

`docker-compose -f docker-compose.local.yml up`

Все остальные действия (`restart`, `stop`, ...) привязанные к "локальному боту" нужно выполнять с флагом `-f docker-compose.local.yml`

Не забудьте отключить бота из образа командой `docker-compose down`

# Установка в Dokku

Подробнее о деплое через Dokku можно прочитать [здесь](https://dokku.com/docs/deployment/application-deployment/).

На сервере:

```bash
dokku apps:create tgvkbot
dokku postgres:create tgvkbot_db
dokku postgres:link tgvkbot_db tgvkbot

dokku config:set tgvkbot BOT_TOKEN=<tg_token> [VK_APP_ID=<vk_app_id> ALLOWED_USER_IDS=<tg_user_ids,...> MAX_FILE_SIZE=<num> ...]
```

На локальном компьютере/где угодно в папке с репозиторием:

```bash
git remote add dokku dokku@<dokku_host_url>:tgvkbot
git push dokku
```


# Сервисы музыки (Устаревшие)
Ниже прокси для музыки, которые использовали ранее. Сейчас они нерелевантны, но код открыт и в боте есть поддержка кастомных бэкендов музыки.

API - https://github.com/Kylmakalle/thatmusic-api

Token Refresher - https://github.com/Kylmakalle/vk-audio-token/tree/refresh-api


# Лицензия
MIT
