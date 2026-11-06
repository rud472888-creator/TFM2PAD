#import <UIKit/UIKit.h>
NSDictionary *TFMSteamLoaderProbe(UIView *host, BOOL startEngine);
NSDictionary *TFMSteamLoginProbe(UIView *host, void (^onQRCode)(UIImage *), void (^onStatus)(NSString *));
