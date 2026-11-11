# 可选自托管后端（开发原型，不是生产医疗服务）

后端与万叶项目完全独立。iPhone 默认本机分析不需要本服务。这里真实实现的是 **FastAPI + SQLite持久任务账本 + 本地私有图片 + ThreadPoolExecutor**，不是声称已部署的 Postgres/Celery/S3 集群。仅支持一套安装、一个私密令牌、一个服务进程；不提供多用户注册/权限系统。

## 运行（Python 3.12）

在本项目 `backend` 目录运行（以下为 PowerShell）：

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
# 每套安装单独生成，勿把输出发到聊天、截图或提交到代码库。
$env:RUYUAN_API_TOKEN = (& .\.venv\Scripts\python.exe -c "import secrets; print(secrets.token_urlsafe(48))")
$env:RUYUAN_DATA_DIR = "$PWD\private-data"
.\.venv\Scripts\python.exe -m uvicorn ruyuan.app:create_app --factory --host 127.0.0.1 --port 8000 --workers 1 --no-access-log
```

令牌必须至少32字符，空令牌/短占位符会拒绝启动。`.env.example` **不会被Python自动加载**；自行将变量导入当前进程。令牌只存在环境和客户端安全存储，SQLite中的所有者由服务端计算令牌SHA-256，不接受请求指定owner。旧令牌轮换后，旧资料不会自动迁移到新所有者；先备份并规划迁移/删除，不要以为换令牌会删除旧照片。

浏览器/手机不能通过手机自己的 `127.0.0.1` 访问电脑。手机联调需自行配置受信HTTPS域名、TLS反向代理、防火墙/局域网访问，App填写该HTTPS地址与同一令牌。不要为了联调全局关闭ATS，也不要将本服务裸露到公网。除健康检查外均需 `Authorization: Bearer <token>`。

## 真正启用人脸模型（明确选择，不会自动下载）

默认 `RUYUAN_FACE_MODEL` 未配置，任务会明确失败为 `model_not_configured`，不会生成随机报告。本地Apple Vision流程仍可使用。

1. 阅读 [Google官方Face Landmarker说明及模型下载/各组件模型卡](https://developers.google.com/edge/mediapipe/solutions/vision/face_landmarker?tab=Python) 与 [MediaPipe仓库LICENSE](https://github.com/google-ai-edge/mediapipe/blob/master/LICENSE)。官方模型表提供兼容的 `.task` 下载，不要把任意 `.tflite` 当任务包。
2. 运维自行审核来源、版本、SHA-256、用途、模型卡与每个组件授权，获授权后下载到私有目录。本项目不捆绑模型，不代替商业/隐私合规审查。[Face Mesh V2官方模型卡](https://storage.googleapis.com/mediapipe-assets/Model%20Card%20MediaPipe%20Face%20Mesh%20V2.pdf) 标明该组件采用Apache-2.0，主要面向AR娱乐，不是临床决策模型；不要据此推定整个打包任务及其全部组件无需核对授权。
3. 安装可选运行时并指定已审核文件：

```powershell
.\.venv\Scripts\python.exe -m pip install -r requirements-face.txt
$env:RUYUAN_FACE_MODEL = 'C:\private-models\face_landmarker.task'
# 再按上面的单进程命令启动
```

模型输出真实关键点后，服务计算像素纵横比修正的面部宽高、眼距/脸宽、口宽/脸宽，以及双颊多边形区域的亮度和相对偏红像素。颜色覆盖图是按真实像素阈值生成的分块代理蒙版，**不是**痘痘、毛孔、炎症或皱纹分割。图像亮度不代表水分/油脂，偏红不代表敏感。水油、肤色、敏感、光滑、衰老五项 `score` 一律 `null`，没有总分、审美评分、医学诊断或治疗建议。报告 `status` 为 `partial`，任务完成不等于临床项目齐全。光照、白平衡、姿态、妆容会改变结果。

图片会校正EXIF朝向、去除元数据并重新编码为JPEG；服务端处理版不声称是用户上传的逐字节原件。只接收单张JPEG/PNG，拒绝动画、损坏文件、小于256px的边、超过20MiB的文件或超过2400万像素。传输体也有限制（图片上限加256KiB multipart开销），不信任扩展名、MIME或用户文件路径。

## App/API契约

- `GET /healthz`：无需鉴权，返回存活状态与 `modelConfigured`（只表示模型文件已配置且存在，不保证模型有效）。
- `POST /v1/uploads`：multipart字段名 `file`，必填HTTP头 `Idempotency-Key: <操作唯一键>`，201 `{ "assetId": "…" }`。同一键与相同上传字节重复请求返回同一个assetId（可恢复丢失回执），换图片字节409；键须与之后创建分析时一致。
- `POST /v1/consents`：`{"purpose":"skin_appearance_analysis","version":"1.0"}`，201 `{ "consentId": "…" }`。它记录当前安装令牌的同意事件，不冒充完整法律同意管理平台。
- `POST /v1/analyses`：`{"assetId":"…","consentId":"…","idempotencyKey":"唯一键"}`，202任务JSON；幂等键8～128字符，可用字母、数字、`_.:-`。重复相同键/相同参数返回同一任务，不重复推理；同一键换参数409。一个图片不能同时运行多个任务。
- `GET /v1/analyses/{id}`：`{"id":"…","stage":"…","status":"…","progress":0.4,"reportId":null,"error":null}`。`progress` 为0～1；stage为 `preparing / quality_checking / geometry / skin_models / report_render`；status为 `queued / running / completed / failed`，删除后查询404。`error` 是可空 **字符串**，不返回堆栈/路径/图片。
- `GET /v1/reports/{id}`：与 `iOS/Ruyuan/Models/AnalysisModels.swift` 的 `AnalysisReport` 完整camelCase结构一致；`createdAt` 为UTC ISO8601字符串。坐标为朝向已校正原图的[0,1]、左上原点，`origin="server"`。`totalScore` 是Swift计算属性，不在JSON中。
- `GET /v1/assets/{id}`：鉴权后返回私有JPEG；不提供静态文件目录或可公开拼出的图片URL。所有响应 `Cache-Control: no-store`。
- `DELETE /v1/analyses/{id}`：取消/删除任务，同时删其报告及不再被其他未删除任务引用的图片。运行中结果被丢弃；原生模型调用无法安全强杀，线程会在调用返回/下个检查点退出。
- `DELETE /v1/reports/{id}`：删除报告、关联任务及不再使用的图片。没有独立保留报告/照片的隐藏副本功能。
- `DELETE /v1/assets/{id}`：清理上传后尚未绑定任务的图片；已被任务引用返回409，需先删除任务。适用于上传后创建任务失败、尚无任务ID的取消。
- `DELETE /v1/operations/{key}`：**推荐的取消/删除入口**。即使上传/创建请求的回执丢失、还不知道assetId或jobId，也能用事先持久化的操作键写入取消墓碑，并删本键绑定的图片、任务和报告。之后正在接收/解码的上传不能提交；并发创建任务也不能越过同一事务检查。对同一键重复调用204，取消先于上传到达也有效，重启后仍有效。

DELETE对已删除/未知/不属于当前令牌的ID均返回204（不透露存在性）。操作删除也只对当前令牌计算的owner生效，同名操作键不会删其他令牌的资料。删除保留最小幂等/取消墓碑及同意事件（键、ID和上传摘要，不保留报告正文或图片）；墓碑原键再次POST返回410，避免网络重试复活已删任务。真正重试失败分析应显式新建幂等键并以该键重新上传图片；已有失败任务不会后台无限重试。禁止拿其他操作的assetId绑定新键。

客户端应：**任何POST之前**持久保存操作键、服务器地址与关联本机图片→带该键上传→取得同意ID→用同键创建任务→持久保存任务ID→轮询；完成后拉取reportId，失败展示 `error`。上传回执丢失时，用原键和同一图片字节重试上传；任务ID取到之前创建回执不确定时，用原键原参数重试创建。已取到任务ID则恢复GET，不重新上传。用户取消就DELETE操作键，即使所有回执未知也安全；HTTP不确定时重试同一DELETE，服务器204后再清本机待处理状态。取消墓碑会阻止迟到请求复活资料。模型未配置时提示配置或切回本机分析，不用演示数据冒充结果。

## 持久性、删除与安全边界

SQLite和照片位于 `RUYUAN_DATA_DIR`，不是代码静态目录。任务状态与结果提交在事务里；启动把当前令牌的中断任务重新入队，最多累计3次尝试，超过则 `restart_limit_reached`。已完成/失败任务不自动重跑。内核文件锁拒绝同时启动两个进程，不要启用多个Uvicorn workers。ThreadPool不是外部队列，不具备跨主机调度、硬超时、弹性扩容或高可用保证。

没有请求正文/人脸/令牌日志、没有云模型调用，也不自动下载模型。请关闭反向代理敏感日志。健康端点及依赖导入成功不代表人脸模型推理已验收。固定依赖经过本机兼容性检查，但仍需部署前漏洞扫描和Linux镜像验证。

目录使用OS私有权限（POSIX创建请求0700；Windows须运维核对ACL）。**磁盘未由应用层加密**，需要BitLocker/FileVault/LUKS等主机加密、受控备份、独立服务账号和最小权限。API删除是逻辑删除和活动文件删除，不保证SSD、SQLite WAL/空闲页、系统快照或备份的取证级擦除；完整清除必须停服务并按组织保留策略处理数据库、卷和备份。尚无自动保留期、账户注销、审计合规、速率限制/磁盘配额或对外多用户隔离平台；不能直接宣称生产就绪。

## Docker（可选，未在本机验证镜像运行）

```powershell
# backend目录；.env自行填写每套安装私密随机token，不能保留空值。
Copy-Item .env.example .env
docker compose --profile backend up --build -d
```

默认只绑定电脑回环地址8000端口，私有资料进入 `ruyuan-private` 命名卷。默认不安装人脸运行时。若选择启用，将审核后的任务包放入 `backend/models/face_landmarker.task`，`.env`设置 `INSTALL_MEDIAPIPE=true` 和 `RUYUAN_FACE_MODEL=/models/face_landmarker.task` 后重新构建。构建需要联网下载公开依赖，运行时不需要联网拉取模型。删除容器不删除命名卷；`down -v` 会丢资料，不要用于普通重启。

## 已执行验证

Windows Python 3.12.7隔离虚拟环境中：

```powershell
.\.venv\Scripts\python.exe -m pip install -r requirements-dev.txt
.\.venv\Scripts\python.exe -m pytest
.\.venv\Scripts\python.exe -m pip check
```

27项API/账本测试通过：鉴权、跨令牌读写隔离、真实未配置模型失败、上传损坏/尺寸/像素/格式/流式体上限、路径与EXIF元数据隔离、同意校验、幂等/冲突/删除墓碑、重启恢复与重试上限、完成/运行中删除与迟到结果丢弃；新增上传幂等回执、取消先于上传、取消上传后创建前、取消完成任务、取消跨令牌隔离、重启保留取消墓碑，以及真实解码期间取消阻止迟到图片提交。只在测试文件通过依赖注入使用确定性假分析器，生产没有启用假结果的环境开关。可选MediaPipe 0.10.21实际导入和FaceLandmarkerOptions创建通过，`pip check` 无冲突。尚未使用真人照片及已授权模型进行端到端推理、未运行Docker、未做真实iPhone网络联调或安全渗透；这些不能由测试桩通过替代。
