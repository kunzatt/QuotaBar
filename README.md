# QuotaBar

[English](README.en.md)

QuotaBar는 여러 ChatGPT Plus, Pro, Pro Lite Codex 계정과 Claude Code(claude.ai Pro·Max) 계정의 남은 쿼터를 macOS 메뉴바에서 확인하는 앱입니다. 대표 계정의 `41%` 같은 잔여량을 메뉴바에 표시하고, 클릭하면 초기화 시각과 계정 상태를 우선한 사용량 패널을 엽니다. 포인터를 올리면 대표 계정 요약을 툴팁으로 보여주며 시스템 라이트·다크 모드를 자동으로 따릅니다.

Finder와 Desktop에는 파란 게이지 심볼 아래 굵은 `Quota Bar` 텍스트가 있는 전용 앱 아이콘을 사용하고, 메뉴바에도 같은 게이지 모양을 표시합니다.

> 스크린샷 자리: 첫 실행 후 메뉴바의 QuotaBar 아이콘과 팝오버를 캡처해 이곳에 추가하세요.

## Homebrew 설치와 원격 업데이트

Apple Silicon Mac에서는 Homebrew Cask로 설치할 수 있습니다. Cask 이름은 `quotabar`입니다.

```zsh
brew tap kunzatt/quotabar https://github.com/kunzatt/QuotaBar.git
brew trust --cask kunzatt/quotabar/quotabar
brew install --cask quotabar
```

첫 설정 뒤에는 `brew install --cask quotabar`과 `brew upgrade --cask quotabar`만 사용하면 됩니다.

새 버전이 GitHub Release에 올라온 뒤 다음 명령으로 원격 업데이트합니다.

```zsh
brew update
brew upgrade --cask quotabar
```

### CodexBar에서 옮겨오기

QuotaBar는 0.2.0부터 쓰는 새 이름이며, 이전 이름은 CodexBar(`codexbar-for-mac`)였습니다. 이미 CodexBar를 쓰고 있다면 앱을 종료한 뒤 다음을 실행합니다. 계정 데이터를 지우지 않도록 `--zap`은 붙이지 마세요.

```zsh
brew uninstall --cask codexbar-for-mac
brew untap kunzatt/codex-bar-for-mac
brew tap kunzatt/quotabar https://github.com/kunzatt/QuotaBar.git
brew trust --cask kunzatt/quotabar/quotabar
brew install --cask quotabar
```

QuotaBar를 처음 실행하면 `~/Library/Application Support/CodexBar`의 계정 데이터를 `QuotaBar` 폴더로 옮기므로 연결한 계정이 그대로 유지됩니다. 로그인 시 실행을 켜 두었다면 새 앱으로 다시 등록합니다.

제거할 때 로그인 프로필까지 지우려면 다음을 사용합니다.

```zsh
brew uninstall --zap --cask quotabar
```

릴리스 제작자는 앱의 `CFBundleShortVersionString`을 올린 뒤 아래 명령으로 GitHub Release용 ZIP과 SHA-256을 생성합니다. 생성된 SHA-256을 `Casks/quotabar.rb`에 반영하고, ZIP을 같은 버전의 `v<version>` GitHub Release에 업로드합니다.

```zsh
./scripts/package-release.sh
```

## 요구 사항

- 배포 ZIP/Homebrew Cask: macOS 14 Sonoma 이상 Apple Silicon Mac
- 소스 빌드: macOS 14 Sonoma 이상 Apple Silicon 또는 Intel Mac, 전체 Xcode(권장) 또는 Swift 6 명령행 도구
- ChatGPT 앱 또는 Codex CLI. 기본 탐색 경로는 `/Applications/ChatGPT.app/Contents/Resources/codex`입니다.
- ChatGPT Plus, Pro 또는 Pro Lite로 로그인할 수 있는 Codex 계정
- Claude Code 계정을 쓰려면 Claude Code CLI(`claude`)와 claude.ai Pro 또는 Max 구독. `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, PATH 순으로 찾습니다.

Codex 계정은 OpenAI Platform API 키, 웹 스크래핑, 비공식 REST 엔드포인트 없이 로컬 `codex app-server --stdio`만 호출합니다.

Claude Code에는 사용량을 묻는 로컬 프로토콜이 없습니다. 그래서 Claude Code 계정은 Claude Code의 `/usage` 화면이 쓰는 `https://api.anthropic.com/api/oauth/usage`를 직접 호출합니다. 이 엔드포인트는 공개 문서가 없는 비공식 API이므로 예고 없이 바뀔 수 있습니다.

## 빌드와 실행

Xcode가 설치된 환경에서는 [QuotaBar.xcodeproj](QuotaBar.xcodeproj/project.pbxproj)를 열고 `QuotaBar` scheme을 실행합니다. 앱은 `LSUIElement` 설정을 사용하므로 Dock 아이콘 없이 메뉴바에서만 동작합니다.

터미널에서는 다음을 실행할 수 있습니다.

```zsh
cd QuotaBar
./scripts/build.sh
```

터미널 없이 실행할 `.app` 번들은 다음 명령으로 만듭니다.

```zsh
cd QuotaBar
./scripts/package-app.sh
open dist/QuotaBar.app
```

생성된 `dist/QuotaBar.app`을 `/Applications`로 드래그하면 일반 macOS 앱처럼 Finder나 Spotlight에서 실행할 수 있습니다. 같은 앱을 터미널과 Finder에서 동시에 실행하면 메뉴바 항목이 중복되므로, 한 방식만 실행하세요.

한 위치에 설치한 앱을 이후 버전으로 교체하려면 앱을 먼저 종료한 뒤 다음을 실행합니다. 기존 번들은 휴지통으로 이동하므로 필요하면 복구할 수 있습니다.

```zsh
cd QuotaBar
./scripts/install-or-update.sh "$HOME/Applications/QuotaBar.app"
```

다른 위치를 계속 쓰려면 해당 위치를 인자로 넘기면 됩니다. 예를 들어 Desktop 설치본은 `./scripts/install-or-update.sh "$HOME/Desktop/QuotaBar.app"`로 갱신합니다.

전체 Xcode가 없으면 스크립트가 Swift Package 빌드로 대체합니다. 이는 소스 컴파일 검증용이며, 메뉴바 UI 실행에는 macOS GUI 세션이 필요합니다.

## 테스트

프레임워크 의존성이 없는 단위 테스트 러너는 다음과 같습니다.

```zsh
cd QuotaBar
./scripts/test.sh
```

현재 테스트는 JSONL 응답/알림 디코딩, multi-bucket 제한, primary/secondary window, null payload, `Int64` 토큰, malformed JSONL 복구, 기간 포맷, backoff, 메타데이터 저장, 로그 마스킹, Claude 사용량 매핑, Claude Keychain 항목 이름, Claude 프로필 생성·삭제를 검증합니다. 실제 계정 로그인이나 인증 파일을 읽지 않습니다.

## 첫 계정 추가

1. 메뉴바의 `C --`를 클릭하고 **계정 추가**를 선택합니다.
2. 별칭을 정하고 **Device Code 로그인 시작**을 누릅니다.
3. 브라우저가 열리면 원하는 ChatGPT Plus, Pro 또는 Pro Lite 계정으로 로그인하고 화면에 표시된 코드를 입력합니다.
4. 로그인 완료 알림을 받으면 QuotaBar가 계정/플랜/쿼터를 다시 읽습니다.

추가 계정도 같은 순서를 반복합니다. 계정마다 독립된 `CODEX_HOME`과 `codex app-server` 프로세스를 사용하므로 인증이 섞이지 않습니다.

기존 기본 Codex 로그인(`~/.codex`)을 쓰려면 설정의 **기본 ~/.codex 등록**을 선택할 수 있습니다. 이 프로필은 외부 프로필로 표시되며, QuotaBar가 디렉터리나 인증 파일을 삭제하지 않습니다.

### Claude Code 계정

1. **계정 연결**에서 서비스를 **Claude Code**로 바꾸고 별칭을 입력한 뒤 **로그인 계속**을 누릅니다.
2. Claude Code가 브라우저를 엽니다. 원하는 claude.ai 계정으로 로그인하면 자동으로 완료됩니다. 브라우저에 코드가 표시되면 QuotaBar 창에 붙여넣고 **제출**을 누릅니다.
3. 계정마다 독립된 `CLAUDE_CONFIG_DIR`을 쓰므로 로그인이 섞이지 않습니다. 이미 터미널에서 쓰는 기본 로그인(`~/.claude`)은 설정의 **기본 ~/.claude 사용**으로 연결합니다.

Claude 사용량은 5시간 한도와 주간 한도로 표시하며, 메뉴바에는 5시간 한도의 잔여량을 보여줍니다. 모델별 주간 한도가 있으면 팝오버에 별도 항목으로 나옵니다. 백그라운드 갱신은 Codex와 같은 주기로 돌지만, 비공식 API 호출은 계정마다 약 1분에 한 번으로 제한합니다. API가 호출 제한(429)을 알리면 `Retry-After`와 5분부터 최대 1시간까지 늘어나는 대기 중 긴 쪽을 지킵니다.

로그인 필요 상태가 되면 사용량 팝오버 또는 설정의 **다시 로그인**을 눌러 Device Code 로그인을 시작할 수 있습니다. 기존 계정 항목과 사용량 기록은 유지되며, 브라우저에서 완료한 계정의 인증 정보만 갱신됩니다.

## 대표 계정과 갱신

- 전체 패널 또는 설정에서 계정 옆의 별을 눌러 대표 계정을 변경합니다. 계정 행 자체는 설정을 바꾸지 않습니다.
- 메뉴바는 대표 계정의 `codex` 버킷을 우선 표시합니다. 여러 기간 한도가 있으면 당장 적용되는 짧은 기간의 잔여량을 표시합니다. 세부 기간별 사용량은 팝오버에서 확인할 수 있습니다. `codex` 버킷이 없으면 첫 번째 제공 버킷을 사용합니다.
- rate limit은 계정마다 30초마다 갱신하고, 토큰 누계는 2분마다 갱신합니다.
- 요청 실패 시 마지막 정상 값은 유지하고 30초 → 60초 → 120초 → 300초 backoff를 적용합니다. Mac이 잠자기에서 깨어나면 즉시 전체 갱신합니다.

## 데이터와 보안

앱이 만든 계정 메타데이터는 다음에 저장됩니다.

```text
~/Library/Application Support/QuotaBar/
├── accounts.json
├── Accounts/<account-uuid>/codex-home/
└── Accounts/<account-uuid>/claude-home/
```

애플리케이션 지원 디렉터리와 계정별 디렉터리는 `0700`, 메타데이터와 생성된 `auth.json`은 가능한 경우 `0600` 권한으로 유지합니다. `accounts.json`에는 별칭, UUID, 로컬 경로, 활성화/대표 계정 설정만 저장합니다.

QuotaBar는 `auth.json`의 내용을 직접 읽거나 파싱하지 않습니다.

Claude Code 계정은 예외입니다. 사용량 API를 호출하려고 Claude Code가 macOS Keychain에 저장한 OAuth 액세스 토큰을 `/usr/bin/security`로 읽습니다. 토큰은 메모리에만 두고 `api.anthropic.com`으로만 보냅니다. 토큰이 만료 2분 전이거나 API가 거부하면, 빈 임시 프로필에서 `CLAUDE_CODE_OAUTH_REFRESH_TOKEN`과 함께 `claude auth login`을 실행해 Claude Code가 새 토큰을 받게 합니다. 새 토큰이 완전한지 확인한 뒤에만 원래 Keychain 항목에 Claude Code와 같은 방식(`security -i`)으로 다시 씁니다. 갱신이 실패해도 원래 로그인은 건드리지 않으며, 임시 프로필과 그 Keychain 항목은 바로 지웁니다. 로그인과 로그아웃도 `claude auth login`/`claude auth logout`이 처리합니다. 토큰·쿠키·API 키·프롬프트·대화 내용도 저장하거나 로그로 남기지 않습니다. stderr는 드레인만 하며 영구 저장하지 않고, 오류 표시도 자격 증명 문자열을 노출하지 않는 일반 메시지로 제한합니다.

## 알려진 제한

- `codex app-server`는 Codex CLI의 experimental 기능입니다. Codex 업데이트로 응답 스키마가 바뀔 수 있으므로 원시 JSON은 `ProtocolMapper` 경계에서만 처리합니다.
- Plus의 5시간 한도는 Codex 서버 응답에 300분 버킷이 있을 때 표시합니다. 서버가 주간 버킷만 보내면 앱은 값을 추정하지 않고 주간 한도만 표시합니다.
- v1은 ChatGPT Plus, Pro, Pro Lite Codex 사용량을 다룹니다. API 비용, 자동 계정 전환, reset credit 자동 소비는 지원하지 않습니다.
- Claude 사용량 API는 비공식이라 Anthropic이 형식이나 인증 방식을 바꾸면 Claude 계정 갱신이 멈출 수 있습니다. 이 경우에도 Codex 계정은 영향을 받지 않습니다.
- 계정별 Claude Keychain 항목 이름은 Claude Code의 현재 규칙(`Claude Code-credentials-<CLAUDE_CONFIG_DIR의 SHA-256 앞 8자리>`)을 따릅니다. Claude Code가 이 규칙을 바꾸면 해당 계정은 로그인 필요로 표시됩니다.
- 실제 device-code 로그인과 메뉴바 상호작용 검증은 GUI와 로그인된 계정이 필요합니다.

## 문제 해결

**Codex 실행 파일을 찾지 못함**

설정에서 `codex` 실행 파일을 직접 선택하세요. ChatGPT 앱 설치본은 일반적으로 `/Applications/ChatGPT.app/Contents/Resources/codex`에 있습니다.

**로그인이 만료됨**

팝오버에서 계정을 다시 추가하거나, 외부 `~/.codex` 프로필이라면 평소 사용하던 Codex CLI 로그인 절차를 완료한 뒤 새로고침하세요.

**사용량이 표시되지 않음**

Codex CLI가 최신인지 확인한 뒤 설정에서 실행 파일 경로를 점검하세요. 계정은 등록되지만 플랜/쿼터가 제공되지 않을 수 있으며, 이 경우 앱은 `C --` 및 마지막 오류 상태를 유지합니다.

**“QuotaBar을(를) 열지 않음” Gatekeeper 경고**

현재 GitHub/Homebrew 배포본은 Apple Developer ID 공증 전의 개인 배포본입니다. 경고가 표시되면 Finder에서 앱을 한 번 실행한 뒤 **시스템 설정 → 개인정보 보호 및 보안 → 그래도 열기**를 선택하세요. Gatekeeper를 전역으로 끄지 마세요. 이 안내는 Developer ID 서명·Apple 공증 릴리스가 준비되면 제거됩니다.

**앱 제거와 인증 파일**

앱 관리 프로필은 설정의 **로그아웃 후 로컬 프로필 삭제**를 선택하면 해당 UUID 계정 폴더만 지웁니다. `~/.codex`를 포함한 외부 프로필은 목록에서만 제거되며, 앱을 삭제해도 인증 파일은 남습니다. 필요하면 Finder에서 `~/Library/Application Support/QuotaBar`를 직접 제거하세요.
