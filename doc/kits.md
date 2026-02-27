# 工具包 (Kits)

ZFinal 提供了丰富的工具类，位于 `zfinal` 命名空间下。这些工具类参考了 JFinal 的设计，并针对 Zig 语言进行了优化。

## 1. StrKit (字符串工具)

字符串处理工具类，提供常用的字符串操作。

```zig
const zfinal = @import("zfinal");
const StrKit = zfinal.StrKit;

// 判断是否为空
if (StrKit.isBlank(str)) { ... }
if (StrKit.notBlank(str)) { ... }

// 去除首尾空白
const trimmed = StrKit.trim("  hello  "); // "hello"

// 分割字符串
const parts = try StrKit.split(allocator, "a,b,c", ",");
defer allocator.free(parts);

// 连接字符串数组
const joined = try StrKit.join(allocator, &.{"a", "b", "c"}, "-"); // "a-b-c"
defer allocator.free(joined);

// 大小写转换
const upper = try StrKit.toUpper(allocator, "hello"); // "HELLO"
const lower = try StrKit.toLower(allocator, "WORLD"); // "world"
const capitalized = try StrKit.capitalize(allocator, "hello"); // "Hello"
defer allocator.free(upper);
defer allocator.free(lower);
defer allocator.free(capitalized);

// 检查是否包含子串
if (StrKit.contains("hello world", "world")) { ... }

// 替换字符串
const replaced = try StrKit.replace(allocator, "hello world", "world", "zig");
defer allocator.free(replaced); // "hello zig"

// 填充字符串
const padded_left = try StrKit.padLeft(allocator, "42", 5, '0'); // "00042"
const padded_right = try StrKit.padRight(allocator, "42", 5, '0'); // "42000"
defer allocator.free(padded_left);
defer allocator.free(padded_right);
```

## 2. HashKit (哈希/加密工具)

提供常用的哈希算法和编码/解码功能。

```zig
const HashKit = zfinal.HashKit;

// MD5 哈希
const md5 = try HashKit.md5(allocator, "password");
defer allocator.free(md5);

// SHA 系列哈希
const sha1 = try HashKit.sha1(allocator, "text");
const sha256 = try HashKit.sha256(allocator, "text");
const sha512 = try HashKit.sha512(allocator, "text");
defer allocator.free(sha1);
defer allocator.free(sha256);
defer allocator.free(sha512);

// Base64 编码/解码
const encoded = try HashKit.base64Encode(allocator, "hello");
defer allocator.free(encoded);
const decoded = try HashKit.base64Decode(allocator, encoded);
defer allocator.free(decoded);

// 生成随机字符串
const random_str = try HashKit.generateRandomString(allocator, 16);
defer allocator.free(random_str);
```

## 3. DateKit (日期工具)

日期和时间处理工具类。

```zig
const DateKit = zfinal.DateKit;

// 获取当前日期
const now = DateKit.now();

// 从时间戳创建日期
const date = DateKit.fromTimestamp(1609459200);

// 格式化日期
const formatted = try date.format(allocator, "%Y-%m-%d %H:%M:%S");
defer allocator.free(formatted); // "2024-01-01 00:00:00"

// 格式化占位符:
// %Y - 四位年份 (2024)
// %y - 两位年份 (24)
// %m - 月份 (01-12)
// %d - 日期 (01-31)
// %H - 小时 (00-23)
// %M - 分钟 (00-59)
// %S - 秒 (00-59)

// 判断闰年
if (DateKit.isLeapYear(2024)) { ... }

// 获取月份天数
const days = DateKit.daysInMonth(2024, 2); // 29
```

## 4. FileKit (文件工具)

文件系统操作工具类。

```zig
const FileKit = zfinal.FileKit;

// 读取整个文件
const content = try FileKit.readFile(allocator, "data.txt");
defer allocator.free(content);

// 写入文件
try FileKit.writeFile("output.txt", "Hello, World!");

// 追加到文件
try FileKit.appendFile("log.txt", "New log entry\n");

// 复制文件
try FileKit.copyFile("source.txt", "destination.txt");

// 删除文件
try FileKit.deleteFile("temp.txt");

// 创建目录
try FileKit.mkdir("data/uploads");

// 删除目录
try FileKit.rmdir("temp_dir");

// 列出目录内容
const entries = try FileKit.listDir(allocator, ".");
defer allocator.free(entries);

// 获取文件大小
const size = try FileKit.fileSize("large_file.bin");
```

## 5. JsonKit (JSON 工具)

JSON 序列化和反序列化工具。

```zig
const JsonKit = zfinal.JsonKit;

const User = struct {
    name: []const u8,
    age: i32,
};

// 解析 JSON
const json_str = "{\"name\":\"Alice\",\"age\":25}";
const parsed = try JsonKit.parse(User, allocator, json_str);
defer parsed.deinit();

// 序列化为 JSON
const user = User{ .name = "Bob", .age = 30 };
const json = try JsonKit.stringify(allocator, user);
defer allocator.free(json);

// 美化 JSON (带缩进)
const pretty = try JsonKit.prettify(allocator, user);
defer allocator.free(pretty);
```

## 6. ArrayKit (数组工具)

数组操作工具类。

```zig
const ArrayKit = zfinal.ArrayKit;

const array = [_]i32{ 1, 2, 3, 4, 5 };

// 检查是否包含
if (ArrayKit.contains(i32, &array, 3)) { ... }

// 查找索引
const index = ArrayKit.indexOf(i32, &array, 3); // ?usize

// 反转数组
var mutable = [_]i32{ 1, 2, 3 };
ArrayKit.reverse(i32, &mutable); // [3, 2, 1]

// 去重
const with_duplicates = [_]i32{ 1, 2, 2, 3, 3, 3 };
const unique = try ArrayKit.unique(i32, allocator, &with_duplicates);
defer allocator.free(unique); // [1, 2, 3]

// 过滤
fn isEven(x: i32) bool { return @mod(x, 2) == 0; }
const evens = try ArrayKit.filter(i32, allocator, &array, isEven);
defer allocator.free(evens); // [2, 4]

// 映射
fn double(x: i32) i32 { return x * 2; }
const doubled = try ArrayKit.map(i32, i32, allocator, &array, double);
defer allocator.free(doubled); // [2, 4, 6, 8, 10]

// 求和、最大值、最小值
const total = ArrayKit.sum(i32, &array); // 15
const maximum = ArrayKit.max(i32, &array); // ?i32 = 5
const minimum = ArrayKit.min(i32, &array); // ?i32 = 1
```

## 7. PathKit (路径工具)

文件路径处理工具类。

```zig
const PathKit = zfinal.PathKit;

// 获取扩展名
const ext = PathKit.getExtension("image.png"); // ".png"

// 获取文件名
const name = PathKit.getBasename("/path/to/file.txt"); // "file.txt"

// 获取目录
const dir = PathKit.getDirname("/path/to/file.txt"); // "/path/to"

// 连接路径
const path = try PathKit.join(allocator, &.{"data", "uploads", "image.png"});
defer allocator.free(path); // "data/uploads/image.png"
```

## 8. RandomKit (随机数工具)

随机数生成工具类。

```zig
const RandomKit = zfinal.RandomKit;

// 生成随机整数
const rand_int = RandomKit.randomInt(i32, 1, 100); // 1 到 100 之间

// 生成随机浮点数
const rand_float = RandomKit.randomFloat(f64, 0.0, 1.0);

// 从数组中随机选择
const items = [_][]const u8{ "apple", "banana", "orange" };
const choice = RandomKit.choice([]const u8, &items);
```

## 9. UrlKit (URL 工具)

URL 编码/解码工具类。

```zig
const UrlKit = zfinal.UrlKit;

// URL 编码
const encoded = try UrlKit.encode(allocator, "hello world");
defer allocator.free(encoded); // "hello%20world"

// URL 解码
const decoded = try UrlKit.decode(allocator, "hello%20world");
defer allocator.free(decoded); // "hello world"

// 解析 Query 参数
const params = try UrlKit.parseQuery(allocator, "name=Alice&age=25");
defer params.deinit();
```

## 10. ValidateKit (验证工具)

数据验证工具类。

```zig
const ValidateKit = zfinal.ValidateKit;

// 验证邮箱
if (ValidateKit.isEmail("user@example.com")) { ... }

// 验证 URL
if (ValidateKit.isUrl("https://example.com")) { ... }

// 验证手机号（中国）
if (ValidateKit.isMobile("13812345678")) { ... }

// 验证身份证号（中国）
if (ValidateKit.isIdCard("110101199001011234")) { ... }
```

## 11. CacheKit (缓存工具)

内存缓存工具类（简化版）。

```zig
const CacheKit = zfinal.CacheKit;

var cache = CacheKit.init(allocator);
defer cache.deinit();

// 设置缓存（带 TTL，单位：秒）
try cache.set("user:1", "Alice", 60);

// 获取缓存
if (cache.get("user:1")) |value| {
    std.debug.print("Found: {s}\n", .{value});
}

// 删除缓存
try cache.delete("user:1");

// 清空所有缓存
try cache.clear();
```


## 12. NumberKit (数字工具)

数字处理和格式化工具类。

```zig
const NumberKit = zfinal.NumberKit;

// 安全转换（带默认值）
const num = NumberKit.toInt("123", 0); // 123
const invalid = NumberKit.toInt("abc", 0); // 0

const float_val = NumberKit.toFloat("3.14", 0.0); // 3.14

// 格式化数字
const formatted = try NumberKit.formatInt(allocator, 12345);
defer allocator.free(formatted); // "12345"

const float_str = try NumberKit.formatFloat(allocator, 3.14159, 2);
defer allocator.free(float_str); // "3.14"

// 限制范围
const clamped = NumberKit.clamp(i32, 15, 0, 10); // 10
const in_range = NumberKit.inRange(i32, 5, 0, 10); // true
```

## 13. FormatKit (格式化工具)

通用格式化工具类，提供各种数据格式化功能。

```zig
const FormatKit = zfinal.FormatKit;

// 格式化文件大小
const size1 = try FormatKit.formatFileSize(allocator, 1024);
defer allocator.free(size1); // "1.00 KB"

const size2 = try FormatKit.formatFileSize(allocator, 1024 * 1024);
defer allocator.free(size2); // "1.00 MB"

// 格式化数字（千分位）
const num = try FormatKit.formatNumber(allocator, 1234567);
defer allocator.free(num); // "1,234,567"

// 格式化百分比
const percent = try FormatKit.formatPercent(allocator, 0.856, 2);
defer allocator.free(percent); // "85.60%"

// 格式化持续时间
const duration = try FormatKit.formatDuration(allocator, 3665);
defer allocator.free(duration); // "1h 1m 5s"

// 截断字符串
const truncated = try FormatKit.truncate(allocator, "Very long text here", 10, "...");
defer allocator.free(truncated); // "Very lo..."
```

## 14. HttpKit (HTTP 工具)

HTTP 相关工具类，包括 MIME 类型、状态码、User-Agent 解析等。

```zig
const HttpKit = zfinal.HttpKit;

// MIME 类型常量
const json_type = HttpKit.MimeType.json; // "application/json; charset=utf-8"
const html_type = HttpKit.MimeType.html; // "text/html; charset=utf-8"

// 根据扩展名获取 MIME 类型
const mime = HttpKit.getMimeType("json"); // "application/json; charset=utf-8"
const img_mime = HttpKit.getMimeType("png"); // "image/png"

// HTTP 状态码描述
const status_text = HttpKit.getStatusText(404); // "Not Found"
const ok_text = HttpKit.getStatusText(200); // "OK"

// 解析 User-Agent
const ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 14_0 like Mac OS X) AppleWebKit/605.1.15";
const parsed = HttpKit.parseUserAgent(ua);
// parsed.is_mobile = true
// parsed.is_bot = false
// parsed.browser = "Safari"
```

## 15. SysKit (系统工具)

系统信息和环境变量工具类。

```zig
const SysKit = zfinal.SysKit;

// 获取环境变量
const path = try SysKit.getEnv(allocator, "PATH");
if (path) |p| {
    defer allocator.free(p);
    std.debug.print("PATH: {s}\n", .{p});
}

// 设置环境变量
try SysKit.setEnv("MY_VAR", "my_value");

// 获取当前工作目录
const cwd = try SysKit.getCwd(allocator);
defer allocator.free(cwd);

// 获取主机名
const hostname = try SysKit.getHostname(allocator);
defer allocator.free(hostname);

// 获取用户名
const username = try SysKit.getUsername(allocator);
if (username) |u| {
    defer allocator.free(u);
}

// 获取系统信息
const info = SysKit.getSystemInfo();
std.debug.print("OS: {s}, Arch: {s}\n", .{info.os, info.arch});

// 执行命令
const output = try SysKit.exec(allocator, &.{"echo", "hello"});
defer allocator.free(output);
```

## 16. TimeKit (时间工具)

时间戳和时间格式化工具类。

```zig
const TimeKit = zfinal.TimeKit;

// 获取当前时间戳（秒）
const now_sec = TimeKit.now(); // 1701234567

// 获取当前时间戳（毫秒）
const now_ms = TimeKit.nowMillis(); // 1701234567890

// 格式化时间戳为 ISO 8601 字符串
const formatted = try TimeKit.format(allocator, 1609459200);
defer allocator.free(formatted); // "2021-01-01T00:00:00Z"

// 睡眠（毫秒）
TimeKit.sleep(1000); // 睡眠 1 秒
```

## 17. RegexKit (正则表达式工具)

简化的正则表达式工具类，支持基本的模式匹配和验证。

```zig
const RegexKit = zfinal.RegexKit;

// 简单通配符匹配
// * 匹配任意字符（0个或多个）
// ? 匹配单个字符
if (RegexKit.match("h?llo", "hello")) { ... } // true
if (RegexKit.match("h*o", "hello")) { ... } // true
if (RegexKit.match("*.txt", "file.txt")) { ... } // true

// 提取所有数字
const numbers = try RegexKit.extractNumbers(allocator, "Price: $123, Qty: 45");
defer allocator.free(numbers); // [123, 45]

// 验证邮箱格式
if (RegexKit.isEmail("user@example.com")) { ... } // true
if (RegexKit.isEmail("invalid.email")) { ... } // false

// 验证 URL 格式
if (RegexKit.isUrl("https://example.com")) { ... } // true
if (RegexKit.isUrl("not-a-url")) { ... } // false
```

**注意**: RegexKit 提供的是简化版正则功能。对于复杂的正则表达式需求，建议使用专门的正则库。


## 使用建议

1. **内存管理**: 大部分返回 `[]const u8` 的函数都需要手动释放内存，记得使用 `defer allocator.free(...)`。
2. **错误处理**: 所有可能失败的操作都会返回 `!Type`，建议使用 `try` 或显式的错误处理。
3. **性能**: Kit 工具类追求易用性，在性能敏感场景建议直接使用 Zig 标准库。
