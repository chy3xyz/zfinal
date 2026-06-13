const zfinal = @import("zfinal");

pub const server = zfinal.ServerConfig{
    .host = "0.0.0.0",
    .port = 8080,
};

// Switch DB driver: zfinal.DBConfig.sqlite("app.db")
//                  zfinal.DBConfig.postgres("host=localhost dbname=app")
//                  zfinal.DBConfig.mysql("host=localhost;user=root;db=app")
pub const database = zfinal.DBConfig.sqliteMemory();

pub const api_prefix = "/api/v1";
