#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <sys/utsname.h>
#import <stdio.h>
#include <pthread.h>
#import "../compat/DisplayCompat.h"
#import "../compat/GLSurface.h"
#import "GameLoaderProbe.h"
#import "SteamLoaderProbe.h"
#import "SteamGameCoordinator.h"
#import "SteamUpdateStatus.h"
#import "../compat/steam/SteamQRAuth.h"
#import "../compat/steam/SteamLaunchPolicy.h"
#import "../compat/steam/SteamCredentialStore.h"

static void ProbeLog(NSString *message) {
    fprintf(stderr, "TFM2Probe: %s\n", message.UTF8String);
    fflush(stderr);
}

static void InputCheckSave(NSString *name,NSDictionary *fields) {
    NSMutableDictionary *record=[fields mutableCopy];
    record[@"pid"]=@(NSProcessInfo.processInfo.processIdentifier);
    record[@"timestamp_unix"]=@(NSDate.date.timeIntervalSince1970);
    NSURL *documents=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSData *data=[NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingPrettyPrinted error:NULL];
    [data writeToURL:[documents URLByAppendingPathComponent:name] options:NSDataWritingAtomic error:NULL];
}

@interface ProbeApplication : UIApplication
@end
@implementation ProbeApplication
- (void)sendEvent:(UIEvent *)event {
    static BOOL enabled;static dispatch_once_t once;static NSUInteger count;
    dispatch_once(&once,^{enabled=[NSProcessInfo.processInfo.arguments containsObject:@"--tfm-input-check"];});
    if (enabled) {
        count++;
        if (count<=32 || !(count%120)) InputCheckSave(@"uikit-event-progress.json",
            @{@"event_count":@(count),@"last_event_type":@(event.type),@"touch_count":@(event.allTouches.count),
              @"scope":@"real UIApplication sendEvent entry; no injection, text or coordinates recorded"});
    }
    [super sendEvent:event];
}
@end

static NSString *LoaderError(void) {
    const char *error = dlerror();
    return error ? [NSString stringWithUTF8String:error] : @"No loader error supplied";
}

static NSDictionary *RunSurvey(NSDictionary *input) {
    ProbeLog(@"Starting import availability survey");
    NSMutableArray *libraries = [NSMutableArray array];
    NSUInteger available = 0, missing = 0, untested = 0, loaderUnresolved = 0;
    for (NSDictionary *spec in input[@"libraries"]) {
        ProbeLog([NSString stringWithFormat:@"Checking %@", spec[@"runtime_path"]]);
        NSMutableDictionary *result = [spec mutableCopy];
        NSMutableArray *symbols = [NSMutableArray array];
        BOOL testable = [spec[@"testable"] boolValue];
        void *handle = NULL;
        if (testable) {
            dlerror();
            // Restrict dlsym to this dependency and its reexports. In particular,
            // never let the executable's compatibility symbols satisfy this
            // raw platform survey through a process-wide fallback.
            handle = dlopen([spec[@"runtime_path"] UTF8String], RTLD_NOW | RTLD_LOCAL | RTLD_FIRST);
            result[@"load_status"] = handle ? @"available" : @"missing";
            if (!handle) result[@"load_error"] = LoaderError();
        } else {
            result[@"load_status"] = @"not_tested";
        }
        NSUInteger libraryAvailable = 0, libraryMissing = 0, libraryUntested = 0;
        for (NSString *import in spec[@"symbols"]) {
            // Mach-O uses one additional underscore, even for C++ mangled symbols.
            NSString *lookup = [import hasPrefix:@"_"] ? [import substringFromIndex:1] : import;
            NSMutableDictionary *entry = [@{@"import": import, @"lookup": lookup} mutableCopy];
            BOOL loaderSpecial = [import isEqualToString:@"dyld_stub_binder"];
            entry[@"category"] = loaderSpecial ? @"loader_special_symbol" : @"imported_api_or_data";
            if (!testable) {
                entry[@"status"] = @"not_tested";
                entry[@"reason"] = spec[@"skip_reason"];
                libraryUntested++;
            } else if (!handle) {
                entry[@"status"] = @"missing";
                entry[@"reason"] = @"Dependent library could not be loaded on this device.";
                libraryMissing++;
            } else {
                dlerror();
                void *address = dlsym(handle, lookup.UTF8String);
                const char *error = dlerror();
                BOOL found = address != NULL && error == NULL;
                entry[@"status"] = found ? @"available" : @"missing";
                if (error) entry[@"error"] = [NSString stringWithUTF8String:error];
                else if (!address) entry[@"error"] = @"Symbol resolved to a null address";
                if (found) libraryAvailable++; else libraryMissing++;
            }
            if (loaderSpecial && [entry[@"status"] isEqualToString:@"missing"]) loaderUnresolved++;
            [symbols addObject:entry];
        }
        result[@"symbols"] = symbols;
        result[@"counts"] = @{@"available": @(libraryAvailable), @"missing": @(libraryMissing), @"not_tested": @(libraryUntested)};
        available += libraryAvailable;
        missing += libraryMissing;
        untested += libraryUntested;
        [libraries addObject:result];
        ProbeLog([NSString stringWithFormat:@"%@ %@: %lu available, %lu missing, %lu untested", spec[@"provider"], result[@"load_status"], (unsigned long)libraryAvailable, (unsigned long)libraryMissing, (unsigned long)libraryUntested]);
        // No retrieved addresses are invoked. Closing only balances our dlopen.
        if (handle) dlclose(handle);
    }
    NSMutableArray *classes = [NSMutableArray array];
    NSUInteger classAvailable = 0;
    for (NSString *name in input[@"objc_class_names"]) {
        BOOL found = objc_lookUpClass(name.UTF8String) != Nil;
        if (found) classAvailable++;
        [classes addObject:@{@"name": name, @"status": found ? @"available" : @"missing"}];
        ProbeLog([NSString stringWithFormat:@"Class %@: %@", name, found ? @"available" : @"missing"]);
    }
    struct utsname machine;
    NSString *hardware = uname(&machine) == 0 ? [NSString stringWithUTF8String:machine.machine] : @"unknown";
    UIDevice *device = UIDevice.currentDevice;
    return @{
        @"schema_version": @1,
        @"status": @"complete",
        @"purpose": @"Raw platform lookup survey. Optional original-code execution is recorded separately under original_game_loader_probe and game-main-progress.json.",
        @"lookup_scope": @"RTLD_FIRST on each dependency handle; executable compatibility exports excluded",
        @"limitations": @[@"Address availability does not establish ABI compatibility or correct behavior.", @"Private or unavailable APIs may not be usable by a shipping iPad app.", @"Vendor Steam imports are not tested.", @"Runtime class checks supplement imported symbols because dynamic class names may be absent from nm.", @"dyld_stub_binder is a loader special symbol. Its unresolved lookup is counted separately from missing API/data imports.", @"Compatibility self-tests are separate from raw platform availability. The game cannot run yet."],
        @"source": input[@"source"],
        @"device": @{@"system_name": device.systemName, @"system_version": device.systemVersion, @"hardware": hardware, @"main_thread_stack_bytes": @(pthread_get_stacksize_np(pthread_self()))},
        @"recorded_at": [[NSISO8601DateFormatter new] stringFromDate:NSDate.date],
        @"libraries": libraries,
        @"objc_classes": classes,
        @"counts": @{@"imported_symbols_available": @(available), @"imported_symbols_missing": @(missing), @"loader_special_symbols_unresolved": @(loaderUnresolved), @"imported_api_or_data_symbols_missing": @(missing - loaderUnresolved), @"imported_symbols_not_tested": @(untested), @"objc_classes_available": @(classAvailable), @"objc_classes_missing": @(classes.count - classAvailable)}
    };
}

@interface ProbeController : UIViewController
@property(nonatomic,strong) UIImageView *steamQR;
@property(nonatomic,strong) UILabel *steamStatus;
@property(nonatomic,strong) UIView *steamPanel;
@property(nonatomic,strong) UIButton *steamCancel;
@property(nonatomic,strong) UIButton *steamFreshLogin;
@property(nonatomic) BOOL steamTerminal;
@property(nonatomic) BOOL steamSavedLoginFailed;
@property(nonatomic) BOOL steamFreshLoginPending;
@property(nonatomic) BOOL steamFreshLoginRequested;
@property(nonatomic) BOOL steamRestartRequired;
@property(nonatomic) BOOL gameImmersive;
@property(nonatomic) CGSize lastGameHostSize;
@property(nonatomic) NSUInteger inputCheckTaps;
@end
@implementation ProbeController
- (void)openGameKeyboard {
    NSURL *path=[NSBundle.mainBundle.privateFrameworksURL URLByAppendingPathComponent:@"TFMAppKit.dylib"];
    void *appKit=dlopen(path.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL|RTLD_FIRST);
    BOOL (*showTextInput)(void)=appKit?dlsym(appKit,"TFMAppKitShowTextInput"):NULL;
    BOOL presented=showTextInput && showTextInput();
    if (appKit) dlclose(appKit);
    if (presented) return;
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"입력할 칸을 선택해 주세요"
        message:@"게임의 입력칸을 선택한 뒤 화면을 두 손가락으로 탭해 주세요."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"확인" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)prepareGamePresentation {
    self.gameImmersive=YES;
    [self setNeedsStatusBarAppearanceUpdate];
    [self setNeedsUpdateOfHomeIndicatorAutoHidden];
}
- (BOOL)prefersStatusBarHidden { return self.gameImmersive; }
- (BOOL)prefersHomeIndicatorAutoHidden { return self.gameImmersive; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return (self.gameImmersive || TFMSteamIconOnlineLaunchRequested()) ? UIInterfaceOrientationMaskLandscape : UIInterfaceOrientationMaskAll;
}
- (NSArray<UIKeyCommand *> *)keyCommands {
    if (!self.gameImmersive) return [super keyCommands];
    UIKeyCommand *keyboard=[UIKeyCommand keyCommandWithInput:@"k" modifierFlags:UIKeyModifierCommand action:@selector(openGameKeyboard)];
    keyboard.discoverabilityTitle=@"게임 키보드 열기";
    return @[keyboard];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (!self.gameImmersive || CGSizeEqualToSize(self.view.bounds.size,self.lastGameHostSize)) return;
    self.lastGameHostSize=self.view.bounds.size;
    // Only notify an already loaded bridge; layout must not initialize AppKit.
    NSURL *path=[NSBundle.mainBundle.privateFrameworksURL URLByAppendingPathComponent:@"TFMAppKit.dylib"];
    void *appKit=dlopen(path.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL|RTLD_FIRST|RTLD_NOLOAD);
    void (*geometryChanged)(void)=appKit?dlsym(appKit,"TFMAppKitHostGeometryDidChange"):NULL;
    if (geometryChanged) geometryChanged();
    if (appKit) dlclose(appKit);
}
- (void)inputCheckTapped:(UIButton *)button {
    self.inputCheckTaps++;
    [button setTitle:[NSString stringWithFormat:@"입력 확인 %lu",(unsigned long)self.inputCheckTaps] forState:UIControlStateNormal];
    button.backgroundColor=UIColor.systemGreenColor;
    InputCheckSave(@"uikit-button-progress.json",@{@"touch_up_inside_count":@(self.inputCheckTaps),@"scope":@"native UIKit diagnostic button only; no game action"});
}
- (void)showInputCheck {
    UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints=NO;
    button.backgroundColor=UIColor.systemOrangeColor;
    [button setTitleColor:UIColor.blackColor forState:UIControlStateNormal];
    [button setTitle:@"입력 확인 0" forState:UIControlStateNormal];
    [button addTarget:self action:@selector(inputCheckTapped:) forControlEvents:UIControlEventTouchUpInside];
    UIWindow *window=self.view.window;
    [window addSubview:button];
    [NSLayoutConstraint activateConstraints:@[
        [button.topAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.topAnchor constant:12],
        [button.trailingAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.trailingAnchor constant:-12],
        [button.widthAnchor constraintEqualToConstant:180], [button.heightAnchor constraintEqualToConstant:48]]];
    InputCheckSave(@"uikit-button-progress.json",@{@"touch_up_inside_count":@0,@"scope":@"native UIKit diagnostic button only; no game action"});
}
- (void)cancelSteamLogin {
    if (self.steamFreshLoginPending) return;
    if (self.steamTerminal) {
        if (self.steamRestartRequired) {
            TFMSteamCancelQRAuthentication();self.steamCancel.enabled=NO;
            self.steamStatus.text=@"앱을 닫고 있습니다. 홈 화면에서 다시 열어 주세요.";return;
        }
        if (TFMSteamCombinedLaunchRequested()) {
            self.steamStatus.text=@"앱 전환 화면에서 이 앱을 완전히 닫은 뒤 다시 열어 주세요.";
            self.steamCancel.hidden=YES;return;
        }
        [self.steamPanel removeFromSuperview];self.steamPanel=nil;return;
    }
    TFMSteamCancelQRAuthentication();
    self.steamQR.image=nil;
    self.steamStatus.text=@"로그인을 취소하고 있습니다.";
}
- (void)requestFreshSteamLogin {
    if (!self.steamSavedLoginFailed || self.steamFreshLoginPending || self.steamFreshLoginRequested) return;
    self.steamFreshLoginPending=YES;self.steamFreshLogin.enabled=NO;
    self.steamCancel.enabled=NO;
    self.steamStatus.text=@"다음 실행에서 새 QR 로그인을 사용하도록 준비하고 있습니다.";
    __weak ProbeController *weakSelf=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        // Keep the saved item. The committed marker bypasses it on the next
        // launch; this never retries or ends the live native Steam session.
        NSDictionary *result=TFMSteamRequestFreshLoginOnNextLaunch(NO);
        BOOL committed=[result[@"restart_required"] boolValue] && [result[@"force_fresh_login"] boolValue];
        dispatch_async(dispatch_get_main_queue(),^{
            ProbeController *controller=weakSelf;if (!controller) return;
            controller.steamFreshLoginPending=NO;
            controller.steamFreshLoginRequested=committed;
            controller.steamFreshLogin.enabled=!committed;
            controller.steamCancel.enabled=YES;
            controller.steamCancel.hidden=!controller.steamRestartRequired;
            [controller.steamCancel setTitle:@"앱 닫기" forState:UIControlStateNormal];
            if (committed) {
                [controller.steamFreshLogin setTitle:@"다음 실행: 새 QR 로그인" forState:UIControlStateNormal];
                controller.steamStatus.text=@"새 QR 로그인 준비를 마쳤습니다. 앱 전환 화면에서 이 앱을 위로 쓸어 완전히 닫은 뒤 다시 열어 주세요.";
            } else {
                controller.steamStatus.text=@"새 QR 로그인 준비를 저장하지 못했습니다. iPad의 잠금을 해제한 상태에서 다시 눌러 주세요.";
            }
        });
    });
}
- (void)updateSteamPhase:(NSString *)phase {
    if ([phase isEqual:@"game_steam_restart_required"]) {
        self.steamRestartRequired=YES;self.steamTerminal=YES;
        self.steamQR.image=nil;
        self.steamCancel.hidden=NO;
        self.steamCancel.enabled=!self.steamFreshLoginPending;
        [self.steamCancel setTitle:@"앱 닫기" forState:UIControlStateNormal];
    }
    if (self.steamFreshLoginPending || self.steamFreshLoginRequested) return;
    if (TFMSteamCombinedLaunchRequested() &&
        ([@[@"saved_steam_sign_in_unavailable",@"saved_steam_sign_in_failed_restart_for_qr"] containsObject:phase]))
        self.steamSavedLoginFailed=YES;
    if (self.steamSavedLoginFailed) {
        self.steamTerminal=YES;self.steamQR.image=nil;self.steamCancel.hidden=!self.steamRestartRequired;
        self.steamFreshLogin.hidden=NO;self.steamFreshLogin.enabled=YES;
        self.steamStatus.text=@"저장된 Steam 로그인 정보를 사용할 수 없습니다. 새 QR로 로그인하려면 아래 버튼을 누른 뒤 앱을 다시 열어 주세요.";
        return;
    }
    NSDictionary *messages=@{
        @"auth_preconditions":@"Steam 연결을 준비하고 있습니다.",
        @"loading_saved_steam_sign_in":@"저장된 Steam 로그인 정보를 확인하고 있습니다.",
        @"signing_in_with_saved_steam_sign_in":@"저장된 정보로 Steam에 로그인하고 있습니다.",
        @"saved_steam_sign_in_unavailable":@"저장된 Steam 로그인 정보를 사용할 수 없습니다.",
        @"saved_steam_sign_in_failed_restart_for_qr":@"저장된 Steam 로그인에 실패했습니다. 새 QR 로그인에는 앱 재시작이 필요합니다.",
        @"saving_steam_sign_in":@"다음 실행을 위해 Steam 로그인 정보를 저장하고 있습니다.",
        @"steam_sign_in_saved":@"Steam 로그인 정보를 저장했습니다. 게임 연결을 확인하고 있습니다.",
        @"steam_sign_in_not_saved":@"로그인 정보를 저장하지 못했습니다. 게임 연결을 확인하고 있습니다.",
        @"requesting_fresh_qr":@"Steam 로그인 QR 코드를 요청하고 있습니다.",
        @"awaiting_mobile_approval":@"휴대폰의 Steam 앱에서 QR 코드를 스캔하고 로그인을 승인해 주세요.",
        @"mobile_approval_received":@"승인을 받았습니다. iPad의 Steam 연결을 확인하고 있습니다.",
        @"qr_approved_token_delivered_to_engine":@"승인을 받았습니다. Steam 로그인 완료를 확인하고 있습니다.",
        @"waiting_for_engine_logon":@"승인을 받았습니다. Steam 서버의 로그인 완료를 기다리고 있습니다.",
        @"waiting_for_native_subscription":@"Steam 로그인을 확인했습니다. 게임 구매 권한을 확인하고 있습니다.",
        @"checking_original_steam_sdk":@"Steam 로그인 후 게임 연결을 확인하고 있습니다.",
        @"preparing_game_steam_helper":@"로그인을 확인했습니다. 게임 연결을 준비하고 있습니다.",
        @"game_steam_sdk_connected":@"Steam 연결을 마쳤습니다. 게임을 시작합니다.",
        @"game_steam_sdk_failed":@"Steam 연결을 완료하지 못했습니다. 연결 결과를 확인하고 있습니다.",
        @"game_steam_restart_required":@"Steam 연결을 완료하지 못했습니다. 앱 닫기를 누른 뒤 홈 화면에서 다시 열어 주세요.",
        @"steam_engine_logged_on":@"Steam 로그인 완료\n게임 연결과 저장 동기화 검증은 아직 남아 있습니다.",
        @"steam_engine_logged_on_sdk_connected":@"Steam 로그인과 게임 SDK 연결을 확인했습니다.\n저장 동기화는 아직 확인하지 않았습니다.",
        @"steam_engine_logged_on_sdk_failed":@"Steam 로그인은 완료됐지만 게임 SDK 연결에 실패했습니다.",
        @"cancelled":@"로그인을 취소했습니다.",
        @"failed":@"Steam 연결 검사를 완료하지 못했습니다. 연결 결과를 확인하고 있습니다."
    };
    self.steamStatus.text=messages[phase] ?: @"Steam 연결 상태를 확인하고 있습니다.";
    if ([@[@"failed",@"cancelled",@"steam_engine_logged_on",@"steam_engine_logged_on_sdk_connected",@"steam_engine_logged_on_sdk_failed",@"game_steam_sdk_connected",@"game_steam_sdk_failed"] containsObject:phase]) {
        self.steamTerminal=YES;self.steamQR.image=nil;
        NSString *title=self.steamRestartRequired?@"앱 닫기":(TFMSteamCombinedLaunchRequested()?@"앱 다시 열기 안내":@"닫기");
        [self.steamCancel setTitle:title forState:UIControlStateNormal];
    }
    if ([phase isEqual:@"game_steam_sdk_connected"]) [self prepareGamePresentation];
    if ([phase isEqual:@"game_steam_sdk_connected"]) {
        TFMStartCachedGameUpdateChecks();
        [self.steamPanel removeFromSuperview];self.steamPanel=nil;
    }
}
- (void)showSteamLogin {
    UIView *panel=[UIView new];panel.backgroundColor=UIColor.systemBackgroundColor;panel.translatesAutoresizingMaskIntoConstraints=NO;
    self.steamPanel=panel;self.steamTerminal=NO;self.steamSavedLoginFailed=NO;
    self.steamFreshLoginPending=NO;self.steamFreshLoginRequested=NO;self.steamRestartRequired=NO;
    [self.view addSubview:panel];
    [NSLayoutConstraint activateConstraints:@[
        [panel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [panel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [panel.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [panel.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
    UILabel *title=[UILabel new];title.text=@"Steam 로그인";title.font=[UIFont systemFontOfSize:30 weight:UIFontWeightSemibold];title.textAlignment=NSTextAlignmentCenter;
    self.steamQR=[UIImageView new];self.steamQR.contentMode=UIViewContentModeScaleAspectFit;
    self.steamQR.backgroundColor=UIColor.whiteColor;self.steamQR.layer.magnificationFilter=kCAFilterNearest;
    self.steamStatus=[UILabel new];self.steamStatus.numberOfLines=0;self.steamStatus.textAlignment=NSTextAlignmentCenter;
    self.steamStatus.font=[UIFont systemFontOfSize:20];self.steamStatus.text=@"Steam 연결을 준비하고 있습니다.";
    UIButton *cancel=[UIButton buttonWithType:UIButtonTypeSystem];[cancel setTitle:@"로그인 취소" forState:UIControlStateNormal];
    if (TFMSteamCombinedLaunchRequested())
        [cancel setTitle:@"취소하고 앱 닫기" forState:UIControlStateNormal];
    self.steamCancel=cancel;
    [cancel addTarget:self action:@selector(cancelSteamLogin) forControlEvents:UIControlEventTouchUpInside];
    UIButton *freshLogin=[UIButton buttonWithType:UIButtonTypeSystem];
    [freshLogin setTitle:@"새 QR로 로그인" forState:UIControlStateNormal];freshLogin.hidden=YES;
    [freshLogin addTarget:self action:@selector(requestFreshSteamLogin) forControlEvents:UIControlEventTouchUpInside];
    self.steamFreshLogin=freshLogin;
    UIStackView *stack=[[UIStackView alloc] initWithArrangedSubviews:@[title,self.steamQR,self.steamStatus,cancel,freshLogin]];
    stack.axis=UILayoutConstraintAxisVertical;stack.spacing=24;stack.alignment=UIStackViewAlignmentCenter;stack.translatesAutoresizingMaskIntoConstraints=NO;
    [panel addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:panel.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:panel.centerYAnchor],
        [stack.widthAnchor constraintLessThanOrEqualToConstant:600],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:panel.safeAreaLayoutGuide.leadingAnchor constant:24],
        [self.steamStatus.widthAnchor constraintEqualToConstant:540],
        [self.steamQR.widthAnchor constraintEqualToConstant:320],
        [self.steamQR.heightAnchor constraintEqualToConstant:320]
    ]];
}
- (void)viewDidLoad {
    [super viewDidLoad];
    ProbeLog(@"ProbeController viewDidLoad");
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UITextView *text = [UITextView new];
    text.translatesAutoresizingMaskIntoConstraints = NO;
    text.editable = NO;
    text.font = [UIFont monospacedSystemFontOfSize:16 weight:UIFontWeightRegular];
    text.textContainerInset = UIEdgeInsetsMake(24, 20, 24, 20);
    [self.view addSubview:text];
    [NSLayoutConstraint activateConstraints:@[
        [text.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [text.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
        [text.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [text.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
    ]];
    text.text = @"TFM2 iPad API Survey\nDIAGNOSTIC APP, NOT GAME\n\nStarting device API survey…";
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            [self performSurveyInTextView:text];
        } @catch (NSException *exception) {
            ProbeLog([NSString stringWithFormat:@"Survey exception: %@: %@", exception.name, exception.reason]);
            text.text = [NSString stringWithFormat:@"DIAGNOSTIC APP, NOT GAME\n\nSURVEY FAILED\n%@: %@", exception.name, exception.reason];
            NSDictionary *failure = @{@"schema_version": @1, @"status": @"failed", @"exception": exception.name, @"reason": exception.reason ?: @"Unknown"};
            NSURL *documents = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
            NSData *json = [NSJSONSerialization dataWithJSONObject:failure options:NSJSONWritingPrettyPrinted error:NULL];
            [json writeToURL:[documents URLByAppendingPathComponent:@"runtime-survey-error.json"] atomically:YES];
        }
    });
}
- (void)performSurveyInTextView:(UITextView *)text {
    NSError *error = nil;
    NSURL *inputURL = [NSBundle.mainBundle URLForResource:@"survey-input" withExtension:@"json"];
    ProbeLog([NSString stringWithFormat:@"Reading bundled input: %@", inputURL]);
    NSData *data = inputURL ? [NSData dataWithContentsOfURL:inputURL options:0 error:&error] : nil;
    NSDictionary *input = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
    if (![input isKindOfClass:NSDictionary.class] || ![input[@"libraries"] isKindOfClass:NSArray.class]) {
        text.text = [NSString stringWithFormat:@"DIAGNOSTIC APP, NOT GAME\n\nCannot read survey-input.json: %@", error.localizedDescription ?: @"Input missing or malformed"];
        ProbeLog(text.text);
        return;
    }
    // Raw per-framework lookup completes before any compatibility self-tests.
    NSMutableDictionary *report = [RunSurvey(input) mutableCopy];
    NSURL *steamInputURL = [NSBundle.mainBundle URLForResource:@"steam-client-survey-input" withExtension:@"json"];
    if (steamInputURL) {
        NSData *steamData = [NSData dataWithContentsOfURL:steamInputURL];
        NSDictionary *steamInput = steamData ? [NSJSONSerialization JSONObjectWithData:steamData options:0 error:NULL] : nil;
        if ([steamInput[@"libraries"] isKindOfClass:NSArray.class] && [steamInput[@"source"] isKindOfClass:NSDictionary.class]) {
            NSDictionary *steamSurvey = RunSurvey(steamInput);
            NSURL *docs = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
            NSData *json = [NSJSONSerialization dataWithJSONObject:steamSurvey options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:NULL];
            [json writeToURL:[docs URLByAppendingPathComponent:@"steam-runtime-survey.json"] atomically:YES];
            report[@"steam_client_platform_lookup_counts"] = steamSurvey[@"counts"];
        } else report[@"steam_client_platform_lookup_error"] = @"Invalid optional survey input";
    }
    ProbeLog(@"Starting separate display compatibility smoke tests");
    report[@"compat_smoke_tests"] = TFMDisplayCompatSmokeTests(self.view.window.windowScene);
    ProbeLog([NSString stringWithFormat:@"Display compatibility smoke tests: %@", report[@"compat_smoke_tests"][@"status"]]);
    report[@"gles_surface_tests"] = TFMGLSurfaceSmokeTest(self.view);
    ProbeLog([NSString stringWithFormat:@"GLES surface tests: %@", report[@"gles_surface_tests"][@"status"]]);
    BOOL runMain = TFMGameStartupRequested();
    BOOL combinedSteam = TFMSteamCombinedLaunchRequested();
    BOOL loginSteam = [NSProcessInfo.processInfo.arguments containsObject:@"--tfm-steam-login"];
    BOOL startSteam = loginSteam || [NSProcessInfo.processInfo.arguments containsObject:@"--tfm-start-steam-engine"];
    BOOL loadSteam = startSteam || [NSProcessInfo.processInfo.arguments containsObject:@"--tfm-load-steam-client"];
    report[@"original_game_loader_probe"] = (runMain || loadSteam) ? @{@"status": @"skipped_for_explicit_startup_mode", @"game_main_called": @NO} : TFMGameLoaderProbe(self.view);
    if (runMain && loadSteam) report[@"launch_mode_error"] = @"Original main and standalone Steam loader modes are mutually exclusive";
    else if (combinedSteam) {
        [self showSteamLogin];
        __weak ProbeController *weakSelf=self;
        TFMSetSteamGameUIHandlers(^(UIImage *image) { weakSelf.steamQR.image=image; },
            ^(NSString *phase) { [weakSelf updateSteamPhase:phase]; });
        report[@"steam_game_session"]=@{@"status":@"waiting_for_original_game_sdk_call",@"authentication_started":@NO};
    } else if (loginSteam) {
        [self showSteamLogin];
        __weak ProbeController *weakSelf=self;
        report[@"steam_client_loader_probe"] = TFMSteamLoginProbe(self.view, ^(UIImage *image) {
            weakSelf.steamQR.image=image;
        }, ^(NSString *phase) { [weakSelf updateSteamPhase:phase]; });
        NSString *loaderStatus=report[@"steam_client_loader_probe"][@"status"];
        if (![loaderStatus isEqual:@"engine_probe_scheduled"]) [self updateSteamPhase:@"failed"];
    } else if (loadSteam) report[@"steam_client_loader_probe"] = TFMSteamLoaderProbe(self.view, startSteam);
    NSURL *documents = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *destination = [documents URLByAppendingPathComponent:@"runtime-survey.json"];
    [[NSFileManager defaultManager] createDirectoryAtURL:documents withIntermediateDirectories:YES attributes:nil error:&error];
    NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&error];
    BOOL saved = json && [json writeToURL:destination options:NSDataWritingAtomic error:&error];
    ProbeLog([NSString stringWithFormat:@"Report %@: %@ %@", saved ? @"saved" : @"SAVE FAILED", destination, error ?: @""]);
    NSDictionary *counts = report[@"counts"];
    NSMutableString *summary = [NSMutableString stringWithFormat:
        @"TFM2 iPad API Survey\nDIAGNOSTIC APP, NOT GAME\n\n%@ %@ · %@\n\nRaw platform symbol lookups\n  Available: %@\n  Missing lookups: %@\n  API/data missing: %@\n  Loader special unresolved: %@\n  Not tested (Steam): %@\n\nmacOS runtime classes\n  Available: %@\n  Missing: %@\n\n",
        report[@"device"][@"system_name"], report[@"device"][@"system_version"], report[@"device"][@"hardware"],
        counts[@"imported_symbols_available"], counts[@"imported_symbols_missing"], counts[@"imported_api_or_data_symbols_missing"], counts[@"loader_special_symbols_unresolved"], counts[@"imported_symbols_not_tested"], counts[@"objc_classes_available"], counts[@"objc_classes_missing"]];
    NSDictionary *compat = report[@"compat_smoke_tests"];
    NSDictionary *gles = report[@"gles_surface_tests"];
    [summary appendFormat:@"Original game library probe: %@\n(Game main not called)\n\n", report[@"original_game_loader_probe"][@"status"]];
    if (loadSteam) [summary appendFormat:@"Steam client probe: %@\n%@\n\n", report[@"launch_mode_error"] ?: report[@"steam_client_loader_probe"][@"status"], startSteam ? @"Explicit engine diagnostic scheduled; login not requested. See steam-engine-progress.json." : @"Engine start and login not requested."];
    [summary appendFormat:@"GLES surface test (separate)\n  %@\n  %@\n  %@\n\n", gles[@"status"], gles[@"gl_version"], gles[@"gl_renderer"]];
    [summary appendFormat:@"Compat self-test (separate)\n  %@: %@ passed / %@ failed\n", compat[@"status"], compat[@"passed"], compat[@"failed"]];
    for (NSDictionary *test in compat[@"tests"]) [summary appendFormat:@"  %@: %@\n", test[@"name"], test[@"status"]];
    [summary appendString:@"Survey complete. Game behavior is verified separately.\n\nRaw framework details\n"];
    for (NSDictionary *library in report[@"libraries"]) {
        NSDictionary *n = library[@"counts"];
        [summary appendFormat:@"%@ — %@\n  %@ available / %@ missing lookups / %@ untested\n", library[@"provider"], library[@"load_status"], n[@"available"], n[@"missing"], n[@"not_tested"]];
    }
    [summary appendString:@"\nRuntime class lookups\n"];
    for (NSDictionary *entry in report[@"objc_classes"]) [summary appendFormat:@"  %@: %@\n", entry[@"name"], entry[@"status"]];
    [summary appendFormat:@"\n%@\n\nLookup success does not prove ABI compatibility or a working port. An optional staged game library probe executes original Skia code. Original game startup requires the explicit --tfm-run-main launch argument.\n", saved ? @"Saved Documents/runtime-survey.json\nAvailable through Files / file sharing." : [NSString stringWithFormat:@"SAVE FAILED: %@", error.localizedDescription]];
    text.text = summary;
    if (!loadSteam && [NSProcessInfo.processInfo.arguments containsObject:@"--tfm-input-check"]) [self showInputCheck];
    if (!loadSteam && runMain) {
        if (!combinedSteam) [self prepareGamePresentation];
        // Leave the main dispatch queue before entering winit's nested run loop.
        // Otherwise UIKit's queued input and asynchronous main-queue callbacks
        // cannot execute while the original desktop main owns this call stack.
        [NSTimer scheduledTimerWithTimeInterval:0.01 repeats:NO block:^(__unused NSTimer *timer) {
            TFMRunOriginalGameMainIfRequested(self.view);
        }];
    }
}
@end

@interface ProbeSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation ProbeSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
    (void)session; (void)connectionOptions;
    ProbeLog(@"Scene willConnectToSession");
    if (![scene isKindOfClass:UIWindowScene.class]) {
        ProbeLog(@"Unexpected non-window scene");
        return;
    }
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [ProbeController new];
    [self.window makeKeyAndVisible];
    ProbeLog(@"Scene window visible");
}
@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation AppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    (void)application; (void)launchOptions;
    ProbeLog(@"Application didFinishLaunchingWithOptions");
    return YES;
}
- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    (void)application; (void)options;
    ProbeLog(@"Application configurationForConnectingSceneSession");
    UISceneConfiguration *configuration = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:session.role];
    configuration.delegateClass = ProbeSceneDelegate.class;
    return configuration;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        ProbeLog(@"main entered");
        return UIApplicationMain(argc, argv, NSStringFromClass(ProbeApplication.class), NSStringFromClass(AppDelegate.class));
    }
}
