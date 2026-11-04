FROM python:3.6 AS builder
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
