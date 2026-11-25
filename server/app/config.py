from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env", env_file_encoding="utf-8", extra="ignore"
    )

    database_url: str = (
        "postgresql+asyncpg://dictation:dictation@localhost:5432/dictation"
    )
    jwt_secret: str = "change-me"
    jwt_algorithm: str = "HS256"
    access_token_expire_minutes: int = 10080  # 7 天
    cors_origins: str = "*"
    # 手写识别阈值（置信度 0~1），需按真实学生笔迹样本校准
    min_conf: float = 0.5
    # 判定模式：conservative 只自动判"正确"（其余一律待确认，杜绝 OCR 过度自信误判错字）；
    # standard 在置信度达标时也自动判"错字"。
    verdict_mode: str = "conservative"
    # 内置管理员账号（首次启动自动创建）
    admin_username: str = "admin"
    admin_password: str = "jiuqi@236049"


settings = Settings()
