# 知识库：账号管理器的输入与输出（用 API Key 查可用模型）

> 建档：2026-09-22　|　适用：KeyInjector v1.6.0　|　状态：**已按工程实测实现逐条核对**
> 定位：本文是「API Key → 可用模型清单」这件事的**领域知识底座**，记录输入输出契约、厂商端点差异与踩坑点。
> 核对依据：`Sources/KeyInjectorCore/Models/ModelDiscovery.swift`（候选端点与鉴权构造）、`config/providers.json`（厂商预设）。

---

## 一、一句话结论

账号管理器只吃两样东西——**服务商接入地址（BaseURL）+ 身份凭证（API Key）**；
只吐两样东西——**该 Key 被授权的模型清单，或一条能看懂的错误**。
输入里**没有账号密码**，输出里也**看不到余额、其他密钥、账号资料**（除非该服务商接口额外开放余额字段）。

---

## 二、输入契约

| 项 | 必填 | 说明 |
| :--- | :--- | :--- |
| **服务商 BaseURL** | 是 | 例如 `https://api.deepseek.com`、`https://api.openai.com/v1`。决定请求打到哪台机器 |
| **API Key 字符串** | 是 | Bearer 鉴权凭证，等价于身份，**不需要账号用户名密码** |
| 代理 | 否 | 国内直连某些域名（如 `googleapis.com`）需要 |
| 超时参数 | 否 | 探测属短请求，通常 10~20 秒足够 |
| 自定义请求头 | 否 | 少数厂商要求版本头（如 Anthropic 的 `anthropic-version`） |

**本质输入 = 模型服务商的接入地址 + 身份凭证。**

---

## 三、输出契约

### 3.1 成功

- **原始输出**：服务商接口返回的 JSON，含模型 id、模型名称、创建时间、归属账号等字段（字段多少由服务商决定）。
- **UI 输出**：该 Key 有权限调用的**模型清单**（列表，供勾选 / 选择使用）。
- 判断成功的硬标准只有一个：**HTTP 200 且响应体能解析出模型标识**。

### 3.2 失败

| 现象 | 中文含义 | 典型原因 |
| :--- | :--- | :--- |
| **401** | 密钥无效 | Key 写错、已吊销、复制时混入空格或换行 |
| **403** | 无权限 | Key 有效但未开通该模型，或来源 IP 被限 |
| **404 / 接口不支持 `/v1/models`** | 端点没有这个接口 | 该服务商未开放模型列表，或路径不是 OpenAI 风格 |
| **429** | 限流 / 配额耗尽 | 免费额度用尽、并发过高 |
| **网络超时 / 不可达** | 网络不通 | 国内直连海外域名被阻断、DNS 失败、需代理 |
| `MISSING_CREDENTIAL` | **本地缺凭据**（凭据未注入或环境变量未生效） | 与 401 **不是一回事**：401 是「Key 到了但服务商不认」，此项是「Key 根本没上车」 |

> ⚠️ 口径提醒：`MISSING_CREDENTIAL` **不是本工程 KeyInjector 的报错**（工程内不存在该字符串），
> 它来自宿主 / 网关侧。遇到它时应先查「注入是否生效、宿主读的环境变量名是否对」，
> 而不是去换 Key。参见 `docs/error-codes.md` 与 `docs/troubleshooting-codex-gateway-models.md`。

---

## 四、极简数据流

```text
[输入：BaseURL + API Key]
        ↓  管理器组装 HTTP 请求
GET {BaseURL}/models        Header: Authorization: Bearer <key>
        ↓
[输出：可用模型列表 / 报错信息]
```

---

## 五、分清两个层面的输入输出

### 5.1 接口层面（管理器 ↔ 大模型服务商）

- **请求输入**（HTTP Header）：`Authorization: Bearer xxx`
- **接口返回输出**：JSON 对象，`data` 为模型数组

```json
{
  "object": "list",
  "data": [
    {"id": "deepseek-chat",  "object": "model"},
    {"id": "deepseek-coder", "object": "model"}
  ]
}
```

### 5.2 UI 用户层面（人 ↔ 账号管理器页面）

- **用户输入**：API Key 输入框、接口地址输入框
- **用户看到**：模型下拉 / 清单列表，或一段红色报错文字

### 5.3 边界（必须说清的三条）

1. 输入**不要账号密码**，只要 API Key；
2. 输出**只能看到这把 Key 被授权的模型**；
3. 看不到账号密码、余额、其他密钥——**是否能看到余额取决于服务商接口开放能力**（部分厂商另开余额端点，如 OpenRouter 的 `/key`）。

---

## 六、Gemini 场景：走 OpenAI 兼容端点

Google 提供 OpenAI 协议兼容端点，因此可以**完全套用 DeepSeek 那套流程**，无需改代码。

| 项 | 取值 |
| :--- | :--- |
| **API Key** | Google AI Studio 复制的 Gemini Key（形如 `AIza…`；Cloud / 中转凭据形如 `AQ.…`） |
| **BaseURL** | `https://generativelanguage.googleapis.com/v1beta/openai/` ← **末尾 `/` 不能丢** |
| 实际请求 URL | `https://generativelanguage.googleapis.com/v1beta/openai/models` |
| 鉴权头 | `Authorization: Bearer <key>`（与 DeepSeek 完全一致） |

### 工作逻辑（与 DeepSeek 流程一模一样）

1. 管理器拿 `BaseURL + API Key` 发起 GET：`…/v1beta/openai/models`
2. Google 校验这把 Key，返回该 Key 有权限的**全部 Gemini 模型清单**
3. 管理器渲染列表供选择

### ⚠️ 两个坑点

1. **原生协议与兼容协议鉴权方式不同**
   - 原生 Gemini：请求头 `x-goog-api-key: <key>`，或查询参数 `?key=<key>`
   - OpenAI 兼容端点：`Authorization: Bearer <key>` —— 与 DeepSeek 一致
2. **网络**：国内直连 `googleapis.com` 大概率超时 / 失败，需要可访问海外的网络环境，否则直接拿不到模型列表。

### 🧪 一行 curl 验证

```bash
curl https://generativelanguage.googleapis.com/v1beta/openai/models \
  -H "Authorization: Bearer 你的gemini-key"
```

能返回 JSON 模型列表，就说明账号管理器可以正常读取这把 Key。

### 备选方案（不推荐）

| 项 | 取值 |
| :--- | :--- |
| BaseURL | `https://generativelanguage.googleapis.com/v1beta` |
| 鉴权 | 请求头 `x-goog-api-key: <key>` 或 `?key=<key>` |
| 缺点 | 原生协议列模型接口**不是** `/v1/models`，只能手动预置模型名，无法自动探测 |

### Gemini 场景的输入输出小结

- **输入**：`BaseURL=https://generativelanguage.googleapis.com/v1beta/openai/` + Gemini API Key
- **输出**：该 Key 可访问的 gemini 模型数组（`gemini-1.5-flash`、`gemini-2.0-flash` 等），或一条报错

### 配额提醒

Google AI Studio 免费 Key 有**请求速率 / 每日 token 限额**，超出后接口直接返回 **429**。

---

## 七、本工程的实际映射（KeyInjector 落点）

以下是工程代码的事实行为，与上文知识一一对应，供排障时定位。

| 知识条目 | 工程实现 | 位置 |
| :--- | :--- | :--- |
| 输入 = BaseURL + Key | 密钥条目含自定义 `baseURL` 与加密存储的 Secret | `Sources/KeyInjectorCore/Storage/` |
| 候选端点顺序 | ① 自定义端点（或厂商预设）+ `/models` → ② 去掉 `/v1` 的变体 + `/models` → ③ 厂商预设 `healthPath` | `ModelDiscovery.swift` `ModelEndpointProbe.candidates` |
| Bearer 鉴权 | `authStyle = bearer` → `Authorization: Bearer <key>` | `ModelDiscovery.request` |
| Gemini 的 `?key=` 原生风格 | `authStyle = queryKey` 时拼 `?key=`；**但若走自定义端点或 Key 为 `AQ.` 前缀，自动改用 Bearer** | 同上 |
| 兼容多种返回形态 | 解析支持 OpenAI `{"data":[…]}`、Gemini `{"models":[…]}`、Ollama、裸数组**四种形态** | `ModelDiscovery.parseModels` |
| 失败一律给中文口径 | 401/403/429/网络不可达等见「状态码与错误码对照表」 | `docs/error-codes.md` |

**结论**：把 Google 厂商的 BaseURL 填成 `…/v1beta/openai/` 这类自定义端点时，
工程会自动改用 Bearer 鉴权（因为判定为「非厂商预设端点」），
所以**文档里的 Gemini 填法是可直接落地的，不需要改代码**。

### ⚠️ 本工程相关的一条实测坑（真机取证）

同一时刻对 Gemini 两个端点各发一次**不带凭据**的 GET，结果不同：

| 端点 | 无凭据时的响应 |
| :--- | :--- |
| 原生 `…/v1beta/models` | **403** `PERMISSION_DENIED`（明确抱怨没有身份） |
| OpenAI 兼容 `…/v1beta/openai/models` | **404** `Requested entity was not found.` |
| OpenAI 兼容 + 无效 Bearer | **400** `Please pass a valid API key` |

**判据**：兼容端点在没有 `Authorization` 头时会伪装成「接口不存在（404）」。
所以界面上看到 Gemini 兼容端点 404，**先查鉴权头有没有带上**，
再考虑「该服务商不支持模型列表」这一解释——后者是本次实测**已被排除**的结论（补上头之后端点立刻给出 400「请传有效密钥」）。

---

## 八、与其他文档的关系

| 文档 | 关系 |
| :--- | :--- |
| `docs/knowledge-account-protocols.md` | **下游**：三家账号协议调研与数据维度可用性（模型名称 / 剩余额度 / 更新时间），以及据此确定的输入输出契约 |
| `docs/error-codes.md` | 本文引用其中文错误口径；数字状态码以那份为唯一来源 |
| `docs/troubleshooting-codex-gateway-models.md` | 排障实战记录（网关路由缺失、上游 429/503） |
| `docs/architecture.md` | 工程分层与模块职责 |
| `config/providers.json` | 厂商预设 BaseURL、鉴权风格、探测路径的事实来源 |
