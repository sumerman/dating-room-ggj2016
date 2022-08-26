import Config

config :dating_room, http_port: System.get_env("PORT") || 8090
config :dating_room, redis_uri: System.get_env("REDIS_URL") || "redis://localhost:6379/0"
