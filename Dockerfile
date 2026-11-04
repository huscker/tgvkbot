FROM python:3.6-slim AS builder
RUN printf '%s\n' \
    'deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/20211220T000000Z bullseye main' \
    'deb [check-valid-until=no] https://snapshot.debian.org/archive/debian-security/20211220T000000Z bullseye-security main' \
    > /etc/apt/sources.list
RUN apt-get update && apt-get install -y gcc
COPY requirements.txt .
RUN pip install --prefix=/opt/deps -r requirements.txt

FROM python:3.6-slim
COPY --from=builder /opt/deps /opt/deps
ENV PATH=/opt/deps/bin:$PATH
ENV PYTHONPATH=/opt/deps/lib/python3.6/site-packages
ENV PYTHONDONTWRITEBYTECODE=1
WORKDIR /app
COPY . .
RUN python manage.py makemigrations data
RUN useradd -u 10001 -r -s /usr/sbin/nologin appuser
USER 10001
ENTRYPOINT ["sh", "-c", "python manage.py migrate data && exec python telegram.py"]
