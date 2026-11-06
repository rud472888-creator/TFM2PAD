# TFM2PAD

Steam에서 구매한 **팀파이트 매니저 2**를 Apple Silicon Mac에서 **자신의 iPad용 앱**으로 빌드하는 키트입니다. Mac의 원본 게임과 Steam 클라이언트를 읽어 ARM64 iPad 앱을 만들고, 구매자 본인의 Apple 개발 서명으로 설치합니다. 게임 원본, Steam 파일, 완성 앱, 서명 자료는 각자의 Mac에만 보관합니다.

**지원 기준은 macOS 게임 0.7.1 / Steam build 26425267입니다.** Mac용 Steam 클라이언트의 파일 버전도 맞아야 합니다. 지원 여부는 빌드 전에 `check`로 확인할 수 있습니다. 기반 포트는 M4 13형 iPad Pro, iPadOS 27.2에서 Steam 로그인, 캠페인 저장·불러오기, 경기 완료, 4:3 화면과 터치 입력을 확인했습니다. 장시간 플레이 시 메모리 한도로 종료되는 알려진 문제가 있습니다. [호환 범위와 실기 기록](docs/compatibility.md)

## AI에게 맡기기

터미널과 파일에 접근할 수 있는 코딩 AI에 아래 문장을 붙여 넣으세요.

> https://github.com/rud472888-creator/TFM2PAD 를 내 Mac에 새로 clone하고, AGENTS.md에 따라 내 Steam 구매본이 지원되는지 먼저 확인해 줘. 지원되면 4:3 iPad 앱을 빌드하고 내 Apple Team으로 서명해서 연결한 iPad에 설치해 줘. 기존 설치가 있으면 세이브를 먼저 백업해. Apple 로그인과 Steam Guard 승인은 내가 직접 할게. 해시가 다르면 어떤 입력이 달랐는지 알려줘.

## 직접 시작하기

Apple Silicon Mac에 macOS용 Steam 게임을 설치하고, 전체 Xcode를 한 번 실행해 iOS 개발 도구를 준비하세요. Python 3.11 이상과 Git이 필요합니다. 기기를 연결하고 Xcode의 Devices and Simulators 창에서 인식되는지 확인하세요. iPad 설치에는 개발자 모드와 기기용 Apple 개발 서명이 필요합니다.

```bash
git clone https://github.com/rud472888-creator/TFM2PAD.git
cd TFM2PAD
python3 scripts/build.py doctor
python3 scripts/build.py check
python3 scripts/build.py build --output work/first
```

`check`가 `supported_local_inputs`를 출력하면 게임 및 Steam 파일이 검증한 버전과 일치합니다. 첫 빌드는 고정된 버전의 공개 GL4ES 소스를 가져옵니다. CMake와 Ninja가 없으면 프로젝트 전용 환경에 설치합니다. 성공한 앱 경로는 **`work/first/app/TFM2Probe.app`** 입니다.

다음으로 **[Apple 서명 및 iPad 설치 가이드](docs/signing.md)**를 따르세요. Xcode가 처음 서명을 준비하는 방법과 이미 프로필이 있을 때의 명령을 모두 제공합니다. 설치한 앱을 열고 본인의 Steam Guard로 QR을 승인하면 게임이 구매 권한을 확인합니다.

- **iPad 조작** — 4:3 전체 화면, 한 손가락 목록 스크롤, 입력칸 자동 키보드, 원본 앱 아이콘, 게임 모드 등록이 기본 빌드에 들어 있습니다.
- **선택 모드** — 뷰 플러스, 관리, 훈련, 경기 후 평가와 연봉·이적료 패치를 서명 전에 추가할 수 있습니다. [모드 빌드](docs/mods.md)
- **다른 Steam 라이브러리** — 자동 탐색이 어려우면 `doctor`, `check`, `build`에 `--app "/경로/TeamfightManager2.app"`, `--steam-contents "/경로/Steam.AppBundle/Steam/Contents"`를 전달하세요.
- **빌드 실패·갱신** — `work/first/build-report.json`에서 실패 단계와 로그를 찾으세요. 수정 후 새 출력 경로를 사용하세요. 게임 업데이트 뒤에는 원본 해시와 Steam 파일을 다시 검사합니다. [호환성 및 업데이트](docs/compatibility.md)

Team Samoyed 및 Valve와 독립된 개인용 포팅 프로젝트입니다. 호환층에는 AgePad의 MIT 라이선스 코드와 GL4ES를 사용합니다. [출처 및 라이선스 고지](THIRD_PARTY_NOTICES.md)
