# 知识库：账号协议调研与数据维度可用性（OpenAI / DeepSeek / Gemini）

> 建档：2026-09-22　|　适用：KeyInjector v1.6.0　|　状态：**已按官方一手来源逐条取证**
> 调研目标：确认「模型名称 / 模型剩余额度 / 模型更新时间」三个维度在三家协议里**分别能不能拿到、从哪个端点拿、字段叫什么**。
> 取证来源（均为官方一手，非第三方转载）：
> 1. Google 官方 Discovery 规范 `https://generativelanguage.googleapis.com/$discovery/rest?version=v1beta`（revision `20260922`，382 KB）
> 2. DeepSeek 官方 API 文档 `https://api-docs.deepseek.com/api/list-models`、`/api/get-user-balance`
> 3. OpenAI 官方类型定义 `openai-python` 的 `types/model.py` 与官方 Node SDK 的 `resources/models.d.ts`、`resources/admin/organization/*`

---

## 一、一句话结论（先看这个，能省掉大半返工）

**三个维度里，「模型名称」三家都能同步准确拿到；「剩余额度」最多只能拿到 DeepSeek 一家；「模型更新时间」只有 OpenAI 一家给时间戳。**
换言之：**不存在一份能同时满足三个维度、且对三家都成立的协议**。
凡是把这三列并排展示的界面，都必须**逐格标注来源与置信度**，缺格子的地方要如实写「该协议不提供」，不能拿本机观测时间去冒充服务商的更新时间。

---

## 二、三家协议的可查事实（端点级）

### 2.1 OpenAI

| 能力 | 端点 | 结果 |
| :--- | :--- | :--- |
| 模型清单 | `GET /v1/models` | ✅ 字段：`id`、`created`、`object`、`owned_by`、`shutdown_date?` |
| 单模型详情 | `GET /v1/models/{model}` | ✅ 同上 |
| 剩余额度 | — | ❌ **官方 SDK 已无余额端点**（历史 `/dashboard/billing/credit_grants` 已从 SDK 移除） |
| 消费金额 | `GET /v1/organization/costs` | ⚠️ 需 **Admin key**，返回的是**成本**不是余额 |
| 消费限额 | `GET /v1/organization/spend_limit` | ⚠️ 需 Admin key，返回限额配置，不是「剩余额度」 |

**模型对象的权威定义**（摘自 `types/model.py`，逐字）：

```python
id: str            # The model identifier
created: int       # The Unix timestamp (in seconds) when the model was created
object: Literal["model"]
owned_by: str      # The organization that owns the model
shutdown_date: Optional[str] = None   # The date when the model will shut down, or null if not announced
```

> 注意语义：`created` 是**模型发布时间**，不是「这个 Key 的模型上次更新/变动时间」；
> `shutdown_date` 是**下线公告日**，对判断「模型会不会突然消失」比 `created` 更有实用价值。

### 2.2 DeepSeek

| 能力 | 端点 | 结果 |
| :--- | :--- | :--- |
| 模型清单 | `GET /models` | ✅ 字段：`id`、`object`、`owned_by` —— **仅此三个** |
| 剩余额度 | `GET /user/balance` | ✅ **三家唯一直接给余额的端点** |
| 模型更新时间 | — | ❌ 文档中不存在任何时间字段 |

**余额响应结构**（摘自官方文档 Schema，逐字）：

```
is_available    boolean   Whether the user's balance is sufficient for API calls.
balance_infos   object[]  Array
  ├ currency           string   Possible values: [ CNV , USD ]   ← 文档原文如此（应为 CNY/USD，官方文档笔误）
  ├ total_balance      string   The total available balance, including the granted balance and the topped-up balance.
  ├ granted_balance    string   The total not expired granted balance.
  └ topped_up_balance  string   The total topped-up balance.
```

示例值：`{"is_available": true, "balance_infos": [{"currency": "CNY", "total_balance": "110.00", ...}]}`

> 三个坑：
> 1. **金额是字符串**，不是数字，界面要按原文展示，避免浮点误差；
> 2. **可能是多币种数组**（CNY 与 USD 并存），UI 要按币种分行，不能相加；
> 3. `is_available` 是**布尔闸门**，比金额更该上首页——它直接回答「还能不能调」。
> 4. **模型清单没有时间字段**：官方示例只给 `id` / `object` / `owned_by`。

### 2.3 Google Gemini

| 能力 | 端点 | 结果 |
| :--- | :--- | :--- |
| 原生模型清单 | `GET /v1beta/models` | ✅ 字段丰富（见下），**但无任何时间字段** |
| OpenAI 兼容清单 | `GET /v1beta/openai/models` | ✅ 返回 OpenAI 形状（`id`/`object`/`created`/`owned_by`） |
| 剩余额度 | — | ❌ **公开协议中没有余额端点**；官方 Discovery 规范里 `models` 资源无法查配额 |
| 配额与限流 | 无 API | ⚠️ 只能由 **429** 响应或 Cloud Console / Cloud Quotas 侧观察 |

**原生 `Model` 资源字段**（摘自 Discovery 规范 `schemas.Model`，全 13 项）：

```
name, displayName, description, version, baseModelId,
inputTokenLimit, outputTokenLimit, supportedGenerationMethods,
temperature, maxTemperature, topP, topK, thinking
```

> 关键点：
> 1. **`models` 资源的 `Model` 里没有 `updateTime` / `createTime`**。
>    规范中确实存在 `createTime` / `updateTime`，但它们只挂在 **TunedModel（微调模型）、File、CachedContent、Corpus** 等资源上，**普通模型的清单里拿不到**。
> 2. `version` 是**版本号**（如 `001`、`002`），`name` 的命名约定是 `{base_model_id}-{version}`（官方原文示例 `models/gemini-1.5-flash-001`）。
>    它是**版本序号，不是时间戳**，不要当成更新时间展示。
> 3. OpenAI 兼容端点由 Google 官方文档确认：`base_url = "https://generativelanguage.googleapis.com/v1beta/openai/"`、鉴权 `Authorization: Bearer $GEMINI_API_KEY`。
>    **官方该页只演示了 `chat/completions`**，`/models` 能不能列是由实现决定的——（本机行为由「识别模型」实测，属观测而非官方承诺）。

---

## 三、三维度可用性总表（★ 落地时照此标注）

| 维度 | OpenAI | DeepSeek | Gemini（原生） | Gemini（OpenAI 兼容） |
| :--- | :--- | :--- | :--- | :--- |
| **模型名称** | ✅ `id` | ✅ `id` | ✅ `name` / `baseModelId` / `displayName` | ✅ `id` |
| **剩余额度** | ❌ 无余额端点（有成本/限额，需 Admin key） | ✅ `total_balance` + `is_available` + 分币种 | ❌ 无 | ❌ 无 |
| **模型更新时间** | ✅ `created`（发布时间，秒级时间戳）+ `shutdown_date` | ❌ 无 | ❌ 无（`version` 不是时间） | ⚠️ 形状上应有 `created`，但语义同为发布时间，非「本 Key 的变动时间」 |
| **补充可用维度** | `owned_by`、`shutdown_date` | `granted_balance` / `topped_up_balance`、`is_available` | `displayName`、`inputTokenLimit`、`outputTokenLimit`、`supportedGenerationMethods` | — |

**结论口径**：想做到「同步准确」，只能**逐家如实呈现**；
凡是协议不给的维度，一律显示「该协议不提供」并给出来源指路（例如 Gemini 额度指向 Cloud Console）。

---

## 四、确定输入与输出

### 4.1 输入（管理器收什么）

| 项 | 必填 | 说明 |
| :--- | :--- | :--- |
| **BaseURL** | 是 | 决定请求打到哪台机器，例如 `https://api.deepseek.com` |
| **API Key** | 是 | 身份凭证；**不需要账号密码** |
| **协议适配器** | 是 | `openai` / `deepseek` / `gemini-native` / `gemini-openai`——决定「额度维度要不要请求、怎么请求」 |
| 探测开关（可选） | 否 | 是否额外请求额度端点（DeepSeek 才有效，其余直接跳过并标注） |
| 代理 / 超时 / 自定义头 | 否 | 与既有实现一致 |

> **关键设计**：输入里必须有「协议适配器」这一项。
> 因为「余额」这一维度**只有 DeepSeek 有**，如果适配器不知道对方是谁，就会出现「对所有厂商都请求 `/user/balance`」这种必然 404 的错误设计。

### 4.2 输出（管理器吐什么）

**每条模型记录（行级）**：

| 字段 | 含义 | 取值口径 |
| :--- | :--- | :--- |
| `id` | 模型标识 | 直接来自协议 |
| `displayName` | 人类可读名 | 有则用（Gemini `displayName`），无则等于 `id` |
| `source` | **来源** | `协议实测` / `宿主声明` / `名称推断` —— 缺一不可标 |
| `identityTime` | 模型身份时间 | OpenAI `created`（秒级时间戳）→ 转本地时间；无则空 |
| `shutdownDate` | 下线公告 | 仅 OpenAI，可为空 |
| `versionTag` | 版本标签 | 仅 Gemini（`version`），**禁止当作时间展示** |
| `limits` | 上限 | Gemini `inputTokenLimit` / `outputTokenLimit` |

**账号级额度块（Key 级，不是模型级）**：

| 字段 | 含义 | 口径 |
| :--- | :--- | :--- |
| `available` | 还能不能调 | DeepSeek `is_available`；其他厂商取健康探测的 401/402/403/429 结论 |
| `balances[]` | 分币种余额 | DeepSeek `balance_infos`，字符串原样、按币种分行 |
| `quotaSource` | 额度数据来源 | `协议实测 (DeepSeek /user/balance)` / `错误码推断 (429/402)` / `不提供（Gemini / OpenAI）` |
| `observedAt` | 本机观测时间 | **本工具自己的时间戳**，与厂商的"更新时间"严格区分，禁止混用 |

**请求级元数据**：实测端点、耗时、HTTP 状态。

**失败与缺格**：逐端点记录异常；缺字段的格子输出「该协议不提供」+ 指路，**不得留空、不得用观测时间填充**。

### 4.3 一句话数据流

```text
[输入：BaseURL + API Key + 协议适配器]
   ├─ ① GET  {base}/models          → 模型名称（三家通用）
   ├─ ② GET  {base}/user/balance    → 剩余额度（仅 DeepSeek 适配器）
   └─ ③ 解析 created / version / limits
[输出：模型行（含来源与身份时间）+ 额度块（含来源）+ 中文错误]
```

---

## 五、可直接执行的简化需求文案

> 以下这段是给执行者（人或 AI）的任务描述，按它做即可，不需要再看上文。

**目标**：账号管理器在「用 API Key 查可用模型」时，除模型名称外，尽可能同步**准确的**额度与时间维度。

1. **模型名称（必做，三家）**
   调用各家模型清单端点；OpenAI/DeepSeek 取 `id`，Gemini 原生取 `name`/`baseModelId`，兼容端点取 `id`。
   响应形态解析沿用既有 `ModelDiscovery.parseModels`（OpenAI `data` / Gemini `models` / Ollama / 裸数组）。

2. **剩余额度（分厂商，不许统一化）**
   - DeepSeek：请求 `GET /user/balance`，展示 `is_available` + 分币种 `total_balance`（字符串原样）。
   - OpenAI：**不请求余额**（无端点）；只展示健康探测结论；如需成本，另列 `organization/costs`，并注明**需 Admin key**。
   - Gemini：**不请求额度**；标注「该协议不提供，请查 AI Studio / Cloud Console」，429 时显示「配额耗尽」。
   - 三元组必须带 `quotaSource`：协议实测 / 错误码推断 / 不提供。

3. **更新时间（只做能拿到的）**
   - OpenAI：`created` → 展示为「模型发布时间」，并单独展示 `shutdown_date`（下线公告）。
   - DeepSeek：**不展示时间列**（协议无此字段）。
   - Gemini：展示 `version` 时**必须叫「版本号」**，禁止叫「更新时间」。
   - 另外提供本机观测时间 `observedAt`，与厂商时间**分列、分标签**。

4. **准确性红线**
   - 每个非协议直出的值都要标来源；推断值降权显示。
   - 协议不提供的字段禁止留空或用别的时间填充，必须写「该协议不提供」。
   - 所有数字状态码配中文说明（口径见 `docs/error-codes.md`）。

5. **验收方式**
   - DeepSeek 真 Key：应看到余额块（分币种）+ `is_available`。
   - OpenAI 真 Key：应看到 `created` 与可选的 `shutdown_date`，且**没有**余额块。
   - Gemini 真 Key：应看到模型清单，额度格子显示「该协议不提供」。

---

## 六、未验证事项（如实声明，勿当事实用）

1. **Gemini `…/v1beta/openai/models` 的字段全集**：Google 官方兼容文档只演示 `chat/completions`，
   该端点由本工具「识别模型」实测走通，但**其返回是否含 `created`、字段是否与 OpenAI 完全一致，本次未逐字段取证**。
2. **OpenAI 余额历史端点**（`/v1/dashboard/billing/credit_grants`）当前状态未实测；
   本文只确认「官方 SDK 中不存在该资源」，因此按「不可依赖」处理。
3. **OpenAI `/v1/organization/costs`、`spend_limit` 的实际字段与权限要求**取自官方 SDK 签名，未用真实 Admin key 实测。
4. **Gemini 配额查询**是否存在可用的公开 API（如 Cloud Quotas 侧）未取证，本文按「不提供」处理。
5. 本次调研未抓取任何官方模型**价格/下架公告网页**，`shutdown_date` 只依赖接口字段。

---

## 六之二、鉴权前置行为实测（本次真机取证，无凭据请求）

同一台机器、同一时刻，对两个端点各发一次**不带任何凭据**的 GET，结果完全不同——这解释了日常最容易误判的一类报错：

| 端点 | 请求 | 实测响应 |
| :--- | :--- | :--- |
| 原生 `…/v1beta/models` | 无凭据 | **403** `Method doesn't allow unregistered callers…` / `PERMISSION_DENIED` |
| OpenAI 兼容 `…/v1beta/openai/models` | 无凭据 | **404** `Requested entity was not found.` / `NOT_FOUND` |
| OpenAI 兼容 `…/v1beta/openai/models` | `Authorization: Bearer <无效值>` | **400** `Please pass a valid API key` / `INVALID_ARGUMENT` |

**由此可确定两条规律（可当作排障判据，已实测）：**

1. OpenAI 兼容端点**必须有 `Authorization` 头才会进入正常鉴权流程**。
   没有这个头时，它不会像原生端点那样老实报 403，而是丢一个 **404 "not found"**——
   于是同一个「忘了带鉴权头」的故障，在界面上会被读成「**该服务商不支持 /v1/models**」。
2. 一旦补上 `Authorization` 头，端点立刻改口：**400 "Please pass a valid API key"**。
   这说明**端点本身存在且支持模型清单**，此前那条 404 与「接口不存在」无关。

> 落地含义：
> - 本文 `## 三` 表格里 Gemini 兼容端点「形状上应有 `created`」的推断，因第 2 条实测而**可信度提高**（端点确实在正常服务，只是本次未带真 Key 看字段）。
> - UI 遇到 Gemini 兼容端点 404 时，**必须先怀疑鉴权头缺失**，而不是直接下结论「该协议不支持模型列表」；
>   这与 `docs/error-codes.md` 中「404 也可能是端点路径写错」的口径要合并判断。

---

## 七、与其他文档的关系

| 文档 | 关系 |
| :--- | :--- |
| `docs/knowledge-account-manager-io.md` | 上游：账号管理器的输入输出总契约；本文是其**协议级取证与维度扩展** |
| `docs/error-codes.md` | 402/429 等额度类错误的中文口径来源 |
| `config/providers.json` | 厂商预设（BaseURL / 鉴权风格 / 探测路径）的事实来源 |
| `Sources/KeyInjectorCore/Models/ModelDiscovery.swift` | 端点候选与响应解析的既有实现 |
