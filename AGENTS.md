# 구매자의 Mac에서 실행하는 AI용 지침

이 저장소를 iPad 설치 안내로 받은 경우, 명령을 요약하는 데 그치지 말고 구매자의 Mac에서 다음 단계를 실제로 진행한다. 원격 AI에 로컬 도구가 없으면 구매자가 복사할 명령과 정상 결과를 단계별로 제시한다.

1. README와 docs/compatibility.md를 읽는다. 새 폴더에 clone한 뒤 해당 폴더로 이동한다. 생성물은 전부 여기의 무시된 `work/` 안에 둔다.
2. `python3 scripts/build.py doctor`로 Apple Silicon Mac, 전체 Xcode의 iPhoneOS SDK, Python, 설치된 macOS 게임을 확인한다. Steam 라이브러리가 여러 곳이면 실제 설치본의 `--app`과 필요시 `--steam-contents`를 전달한다. 시스템의 전역 Xcode 설정은 바꿀 필요가 없다.
3. `python3 scripts/build.py check`를 실행한다. 성공은 JSON의 `supported_local_inputs`와 종료 코드 0이다. 해시가 바뀌면 해당 이름과 설치 버전을 알려주고 중단한다. 새 해시를 등록하거나 검사를 끄거나 임의의 게임/Steam 다운로드로 우회하지 않는다.
4. `python3 scripts/build.py build --output work/first`를 실행한다. 기존 출력이 있으면 새 이름을 쓴다. 마지막 JSON의 `bundle` 경로와 성공 상태를 확인한다. 도중 중단된 작업은 로그에서 실패 단계를 확인한 뒤 새 디렉터리로 재시작한다. 기본 앱의 4:3 패치는 자동으로 적용된다.
5. 유저가 모드를 원하면 docs/mods.md를 읽고 **서명 전에** 선택한 모드만 추가한다. 기본 앱 설치에 Rust나 커뮤니티 배포 파일은 필요 없다.
6. docs/signing.md에 따라 구매자 자신의 iPad, Apple Team, 고유한 번들 ID를 선택하고 새 복사본을 서명한다. 기존 앱을 업데이트할 때는 원래 Team/ID를 유지한다. 개인 키, 비밀번호, Steam Guard 코드, QR, 토큰, 프로비저닝 프로필, 원본 게임과 세이브를 채팅이나 GitHub에 요청하지 않는다. Apple/Xcode 및 Steam 인증은 구매자가 직접 한다.
7. 설치 요청이 있으면 구매자가 게임을 저장하고 닫은 뒤 가이드의 install 명령을 사용한다. 기존 앱 삭제는 하지 않는다. 앱을 실행하고 구매 권한, 메인 메뉴, 저장 후 재실행을 확인한 범위만 보고한다. 서명이나 설치 영수증만으로 실제 플레이가 성공했다고 보고하지 않는다.

이 프로젝트는 특정 ARM64 macOS 바이너리와 API에 맞춘 포팅이다. 스토어 등록, 게임 재배포, 오프라인 소유권 우회는 빌드 절차에 속하지 않는다.
