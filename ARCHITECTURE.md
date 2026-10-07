# QuotaBar 아키텍처

```text
SwiftUI MenuBarExtra (.window)
                │
                ▼
      UsageStore (@MainActor)
       │              │
       ▼              ▼
AccountRepository   PollingCoordinator (30 s / 2 min)
                       │
                       ▼
                 CodexClientPool actor
                       │
                       ▼
       CodexAppServerClient actor (profile마다 하나)
                       │
                       ▼
       codex app-server --stdio, profile CODEX_HOME
```

## UI와 상태

SwiftUI `MenuBarExtra`의 `.window` 스타일이 메뉴바 항목과 popover-like window를 소유합니다. macOS가 메뉴바 클릭, 바깥 클릭 닫힘, 앱 활성화, 창 수명을 직접 관리하며 hover는 SwiftUI `help` 툴팁만 사용합니다. window는 시스템 라이트·다크 모드를 따릅니다. 대표 계정의 잔여량과 초기화 시각을 먼저 보여주고 제한별 상세를 접을 수 있게 하며, 대표 계정 변경은 명시적인 별 버튼으로만 수행합니다. 설정은 SwiftUI `Settings` scene과 `SettingsLink`가 관리하는 별도 창으로 엽니다.

`UsageStore`는 메인 액터에서 선호 설정과 계정 snapshot을 소유합니다. 한 계정의 실패는 그 계정 snapshot을 stale/auth-required로만 전환하므로 다른 계정의 갱신과 메뉴바는 계속 동작합니다.

## 프로토콜 경계

`JSONValue`, `JSONLMessage`, `JSONLLineBuffer`, `ProtocolMapper`는 app-server의 불안정한 JSON 형태를 캡슐화합니다. DTO 키가 추가되거나 nullable 값이 늘어나도 관대한 디코딩을 하며, UI는 `AccountUsageSnapshot`, `RateLimitBucket`, `TokenUsageSummary` 같은 도메인 모델만 봅니다.

클라이언트는 `initialize` 응답 뒤에만 요청을 전송하고 `initialized` 알림을 보냅니다. stdout은 JSONL buffer가 처리합니다. 잘못된 JSON 한 줄은 건너뛰고 다음 행을 계속 읽습니다. ID가 있는 응답은 actor 내부 continuation 사전에 연결하고, `account/login/completed`는 login waiter에 전달합니다.

`account/rateLimits/read`와 `account/usage/read`는 최신 생성 스키마에 맞춰 params를 생략합니다. `account/read`에는 app-server가 요구하는 `{ "refreshToken": ... }` 필드를 항상 넣으며, 새 프로세스의 첫 요청만 `true`, 이후 폴링은 `false`로 보냅니다. 첫 계정 읽기를 완료한 뒤 사용량 요청을 시작해 만료 직전 세션의 경합을 피합니다. `account/rateLimits/updated`와 `account/updated` 알림은 `UsageStore`에 전달되어 즉시 안전한 read를 다시 요청합니다. 이미 읽는 중이면 한 번의 후속 read를 큐잉하므로 sparse nullable 필드가 마지막 정상 snapshot을 지우지 않습니다.

## Claude Code 계정

Claude Code에는 app-server 같은 사용량 프로토콜이 없습니다. `ClaudeUsageClient` actor가 계정마다 하나씩 있고, 상주 프로세스 없이 다음 순서로 동작합니다.

1. `/usr/bin/security`로 Claude Code의 Keychain 항목을 읽습니다. 이름은 `Claude Code-credentials`이고, `CLAUDE_CONFIG_DIR`을 쓰는 계정은 그 경로의 SHA-256 앞 8자리가 뒤에 붙습니다. Keychain에 없으면 `<config>/.credentials.json`을 읽습니다.
2. 액세스 토큰이 2분 안에 만료되거나 API가 거부하면 Ptah 수집기와 같은 방식으로 갱신합니다. `Application Support/QuotaBar/ClaudeRenewal/<UUID>` 빈 임시 프로필에서 `CLAUDE_CODE_OAUTH_REFRESH_TOKEN`·`CLAUDE_CODE_OAUTH_SCOPES`·`BROWSER=false`로 `claude auth login --claudeai`를 실행합니다. 실패한 교환에서 CLI가 자기 프로필을 비울 수 있기 때문에 원래 프로필을 넘기지 않습니다.
   - 새 액세스 토큰·refresh token·미래 만료 시각·scope가 모두 있어야 성공으로 봅니다. 그동안 원래 항목이 바뀌었으면(Claude Code가 갱신했거나 다시 로그인) 덮어쓰지 않습니다.
   - 성공하면 원래 문서의 `claudeAiOauth`만 교체해 Claude Code와 같은 `security -i` `add-generic-password -U`로 씁니다. 실패하면 원래 로그인은 그대로 두고 5분부터 1시간까지 backoff합니다. `invalid_grant`일 때만 로그인 필요로 전환합니다.
   - 임시 프로필 폴더와 그 Keychain 항목은 결과와 상관없이 지웁니다.
3. `GET https://api.anthropic.com/api/oauth/usage`(비공식)를 호출합니다. `limits`(session, weekly_all, weekly_scoped)를 먼저 300분·10080분 `RateLimitWindow`와 모델별 버킷으로 매핑하고, 없으면 `five_hour`/`seven_day`/`seven_day_<model>`을 씁니다. 401이면 2번을 한 번 거친 뒤 재시도하고, 429면 `Retry-After`와 backoff 중 긴 쪽만큼 호출을 멈춥니다.

폴링은 Codex와 같은 `PollingCoordinator`를 씁니다. 다만 `includeUsage == false`인 주기에는 55초 안의 결과를 재사용하므로 네트워크 호출은 계정당 약 1분에 한 번입니다. 로그인은 `claude auth login --claudeai`를 stdin을 연 채로 실행합니다. 브라우저 콜백으로 끝나지 않으면 사용자가 붙여넣은 코드를 stdin으로 전달합니다. 기본 `~/.claude` 프로필은 `CLAUDE_CONFIG_DIR`을 설정하지 않습니다. 값을 명시하면 Claude Code가 다른 Keychain 항목을 쓰기 때문입니다.

## 계정 격리와 수명

계정은 `CodexClientPool`의 UUID 키와 해당 계정 `CODEX_HOME`으로 분리됩니다. 앱 관리 프로필은 `cli_auth_credentials_store = "file"`을 갖고, `Process.environment["CODEX_HOME"]`이 항상 그 계정 경로를 가리킵니다. 앱은 인증 파일을 해석하지 않습니다.

각 client는 한 지속 프로세스를 유지합니다. 종료 시 pending request/login continuation을 실패 처리하고, 이후 polling refresh가 프로세스를 다시 시작합니다. Polling은 30/60/120/300초 backoff에 작은 jitter를 더하고, 성공하면 기본 주기로 복귀합니다. 앱 종료 요청은 `terminateLater`로 잠시 보류한 뒤 모든 child process에 종료 신호를 보내고 짧은 grace period를 기다린 후 macOS 종료를 승인합니다. 메뉴바 window의 입력과 닫힘에는 별도 AppKit event monitor를 두지 않고 `MenuBarExtra`의 시스템 동작을 사용합니다.

## 저장 및 삭제 안전성

`AccountRepository`는 `accounts.json`을 원자적으로 저장합니다. 이름을 바꾸기 전의 `Application Support/CodexBar`가 남아 있고 `QuotaBar`가 없으면 첫 실행 때 폴더를 그대로 옮기고, 앱 관리 프로필 경로를 새 위치로 고칩니다. Claude 프로필은 Keychain 항목 이름이 폴더 경로에 따라 정해지므로 새 경로의 항목으로 옮깁니다. 앱 관리 프로필 삭제는 `Accounts/<UUID>/codex-home`와 정확히 일치하는 경로인지 확인한 후 그 UUID 폴더만 제거합니다. Application Support 전체나 `~/.codex`를 재귀 삭제하지 않습니다.

## 검증 경계

`scripts/test.sh`는 UI·실제 자격 증명 없이 core Swift source를 컴파일한 뒤 독립 unit runner를 실행합니다. 메뉴바 window 상호작용, device-code 로그인, sleep/wake와 실제 child process 수명은 Xcode/로그인된 macOS GUI 환경에서 수행할 수동 통합 검증 항목입니다.
