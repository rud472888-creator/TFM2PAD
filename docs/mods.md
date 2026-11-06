# iPad용 선택 모드

기본 게임을 먼저 빌드한다. 모드는 구매한 앱의 `mod-sdk-stable`과 Rust 소스로 개인용 iOS 라이브러리를 만든 뒤 **서명 전 앱**에 추가한다. 뷰 플러스·관리·훈련은 게임 설치본만 있으면 빌드할 수 있다. 평점 모드의 원본 한국어 댓글과 밴픽 일러스트는 별도의 커뮤니티 배포본이 필요하다.

1. Rustup이 있는 Mac에서 `rustup toolchain install 1.95.0` 및 `rustup target add --toolchain 1.95.0 aarch64-apple-ios`를 실행한다. 전체 Xcode가 필요하다. 시스템 기본 설정을 바꾸지 않고 아래처럼 이 빌드에만 툴체인을 지정한다.
2. 게임 경로는 `python3 scripts/build.py doctor`가 출력한 `game` 값으로 설정한다.
3. 기본 레이아웃으로 빌드한 후 아래 명령을 실행한다. 결과로 출력되는 **Unsigned modded app**을 기본 앱 대신 서명한다.

```bash
GAME="$HOME/Library/Application Support/Steam/steamapps/common/Teamfight Manager2/TeamfightManager2.app"
RUSTUP_TOOLCHAIN=1.95.0 python3 scripts/mods.py --base work/first/app --app "$GAME"
```

| 추가 옵션 | 개인 빌드에 넣는 기능 |
| --- | --- |
| `--salary` | 검토된 버전의 이적료 및 연봉 패치. 원본 복사본에 적용하고 역변환으로 검증 |
| `--postmatch-dll "/path/to/tfm2_postmatch.dll"` | 검토한 경기 후 평가 4.0.0-beta.14 배포본에서 댓글을 읽어 iPad 평점 모드 생성 |
| `--illustrations "/path/to/illustrations.zip"` | 검토된 밴픽 그림 ZIP을 개인 뷰 플러스 모드에 추가. 이 옵션에만 Pillow 필요 |

일러스트 옵션은 `python3 -m venv work/modenv`, `work/modenv/bin/python -m pip install Pillow` 후 같은 명령의 Python을 `work/modenv/bin/python`으로 바꾸면 된다. 평점 DLL과 그림 ZIP은 각각 해시로 검증한다. 정상적인 외부 배포본을 직접 준비한다. 다른 버전의 DLL이나 그림 ZIP은 중단한다. 링크와 제작자 정보는 원문에서 확인할 수 있다. [경기 후 평가](https://m.dcinside.com/board/teamfightmanager/21736?recommend=1) · [커뮤니티 게시물 19731](https://m.dcinside.com/board/teamfightmanager/19731) · [커뮤니티 게시물 20073](https://m.dcinside.com/board/teamfightmanager/20073) · [커뮤니티 게시물 21760](https://m.dcinside.com/board/teamfightmanager/21760)

설치 후 게임 메뉴의 **모드**에서 각 항목의 활성 상태와 코드 모드 경고를 확인한다. 선수단·영입 화면에서 능력치 보기를, 경기 종료 후 메신저에서 평점을 확인할 수 있다. 이식한 기능과 원본 Windows 모드의 기능 범위에는 차이가 있다.
