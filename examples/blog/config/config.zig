const std = @import("std");
const zfinal = @import("zfinal");

/// 数据库配置
pub const DBConfig = struct {
    pub fn get() zfinal.DBConfig {
        return zfinal.DBConfig.sqlite("blog.db");
    }
};

/// 服务器配置
pub const ServerConfig = struct {
    pub const port: u16 = 8080;
};
