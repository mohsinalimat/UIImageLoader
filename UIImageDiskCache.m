
#import "UIImageDiskCache.h"

/**********************/
/* UIImageMemoryCache */
/**********************/

@interface UIImageMemoryCache ()
@property NSCache * cache;
@end

@implementation UIImageMemoryCache

- (id) init {
	self = [super init];
	self.cache = [[NSCache alloc] init];
	self.cache.totalCostLimit = 25 * (1024 * 1024); //25MB
	return self;
}

- (void) cacheImage:(UIImage *) image forURL:(NSURL *) url; {
	if(image) {
		NSUInteger cost = CGImageGetHeight(image.CGImage) * CGImageGetBytesPerRow(image.CGImage);
		[self.cache setObject:image forKey:url.path cost:cost];
	}
}

- (void) removeImageForURL:(NSURL *) url; {
	[self.cache removeObjectForKey:url.path];
}

- (void) purge; {
	[self.cache removeAllObjects];
}

@end

/* UIImageCacheData */

@interface UIImageCacheData : NSObject <NSCoding>
@property NSTimeInterval maxage;
@property NSString * etag;
@property BOOL nocache;
@end

/* UIImageDiskCache */
typedef void(^UIImageLoadedBlock)(UIImage * image);
typedef void(^NSURLAndDataWriteBlock)(NSURL * url, NSData * data);
typedef void(^UIImageDiskCacheURLCompletion)(NSError * error, NSURL * diskURL, UIImageLoadSource loadedFromSource);
typedef void(^UIImageDiskCacheDiskURLCompletion)(NSURL * diskURL);

//errors
NSString * const UIImageDiskCacheErrorDomain = @"com.gngrwzrd.UIImageDisckCache";
const NSInteger UIImageDiskCacheErrorResponseCode = 1;
const NSInteger UIImageDiskCacheErrorContentType = 2;
const NSInteger UIImageDiskCacheErrorNilURL = 3;

//default disk cache
static UIImageDiskCache * _default;

//private disk cache properties
@interface UIImageDiskCache ()
@property NSURLSession * activeSession;
@property (readwrite) NSURL * cacheDirectory;
@property NSString * auth;
@end

@implementation UIImageDiskCache

+ (UIImageDiskCache *) defaultDiskCache {
	if(!_default) {
		_default = [[UIImageDiskCache alloc] init];
	}
	return _default;
}

- (id) init {
	self = [super init];
	
	//default behaviors
	self.cacheImagesInMemory = FALSE;
	self.trustAnySSLCertificate = FALSE;
	self.useServerCachePolicy = TRUE;
	self.logCacheMisses = TRUE;
	self.logResponseWarnings = TRUE;
	self.etagOnlyCacheControl = 0;
	
	//default memory cache.
	self.memoryCache = [[UIImageMemoryCache alloc] init];
	
	//setup default cache dir
	NSURL * appSupport = [[[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask] lastObject];
	NSURL * defaultCacheDir = [appSupport URLByAppendingPathComponent:@"UIImageDiskCache"];
	[[NSFileManager defaultManager] createDirectoryAtURL:defaultCacheDir withIntermediateDirectories:TRUE attributes:nil error:nil];
	self.cacheDirectory = defaultCacheDir;
	
	return self;
}

- (void) setAuthUsername:(NSString *) username password:(NSString *) password; {
	if(username == nil || password == nil) {
		self.auth = nil;
		return;
	}
	NSString * authString = [NSString stringWithFormat:@"%@:%@",username,password];
	NSData * authData = [authString dataUsingEncoding:NSUTF8StringEncoding];
	NSString * encoded = [authData base64EncodedStringWithOptions:0];
	self.auth = [NSString stringWithFormat:@"Basic %@",encoded];
}

- (void) setAuthorization:(NSMutableURLRequest *) request {
	if(self.auth) {
		[request setValue:self.auth forHTTPHeaderField:@"Authorization"];
	}
}

- (void) clearCachedFilesOlderThan1Day; {
	[self clearCachedFilesOlderThan:86400];
}

- (void) clearCachedFilesOlderThan1Week; {
	[self clearCachedFilesOlderThan:604800];
}

- (void) clearCachedFilesOlderThan:(NSTimeInterval) timeInterval; {
	dispatch_queue_t background = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND,0);
	dispatch_async(background, ^{
		NSArray * files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:self.cacheDirectory.path error:nil];
		for(NSString * file in files) {
			NSURL * path = [self.cacheDirectory URLByAppendingPathComponent:file];
			NSDictionary * attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path.path error:nil];
			NSDate * modified = attributes[NSFileModificationDate];
			NSTimeInterval diff = [[NSDate date] timeIntervalSinceDate:modified];
			if(diff > timeInterval) {
				NSLog(@"deleting cached file: %@",path.path);
				[[NSFileManager defaultManager] removeItemAtPath:path.path error:nil];
			}
		}
	});
}

- (void) setSession:(NSURLSession *) session {
	self.activeSession = session;
	if(session.delegate && self.trustAnySSLCertificate) {
		if(![session.delegate respondsToSelector:@selector(URLSession:didReceiveChallenge:completionHandler:)]) {
			NSLog(@"[UIImageDiskCache] WARNING: You set a custom NSURLSession and require trustAnySSLCertificate but your "
				  @"session delegate doesn't respond to URLSession:didReceiveChallenge:completionHandler:");
		}
	}
}

- (NSURLSession *) session {
	if(self.activeSession) {
		return self.activeSession;
	}
	
	NSURLSessionConfiguration * config = [NSURLSessionConfiguration defaultSessionConfiguration];
	self.activeSession = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:[NSOperationQueue mainQueue]];
	
	return self.activeSession;
}

- (void) URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential * _Nullable))completionHandler {
	if(self.trustAnySSLCertificate) {
		completionHandler(NSURLSessionAuthChallengeUseCredential,[NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust]);
	} else {
		completionHandler(NSURLSessionAuthChallengePerformDefaultHandling,nil);
	}
}

- (NSURL *) localFileURLForURL:(NSURL *) url {
	if(!url) {
		return NULL;
	}
	NSString * path = [url.absoluteString stringByRemovingPercentEncoding];
	NSString * path2 = [path stringByReplacingOccurrencesOfString:@"http://" withString:@""];
	path2 = [path2 stringByReplacingOccurrencesOfString:@"https://" withString:@""];
	path2 = [path2 stringByReplacingOccurrencesOfString:@":" withString:@"-"];
	path2 = [path2 stringByReplacingOccurrencesOfString:@"?" withString:@"-"];
	path2 = [path2 stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
	path2 = [path2 stringByReplacingOccurrencesOfString:@" " withString:@"_"];
	return [self.cacheDirectory URLByAppendingPathComponent:path2];
}

- (NSURL *) localCacheControlFileURLForURL:(NSURL *) url {
	if(!url) {
		return NULL;
	}
	NSURL * localImageFile = [self localFileURLForURL:url];
	NSString * path = [localImageFile.path stringByAppendingString:@".cc"];
	return [NSURL fileURLWithPath:path];
}

- (BOOL) acceptedContentType:(NSString *) contentType {
	NSArray * acceptedContentTypes = @[@"image/png",@"image/jpg",@"image/jpeg",@"image/bmp",@"image/gif",@"image/tiff"];
	return [acceptedContentTypes containsObject:contentType];
}

- (NSDate *) createdDateForFileURL:(NSURL *) url {
	NSDictionary * attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:url.path error:nil];
	if(!attributes) {
		return nil;
	}
	return attributes[NSFileCreationDate];
}

- (void) writeData:(NSData *) data toFile:(NSURL *) cachedURL writeCompletion:(NSURLAndDataWriteBlock) writeCompletion {
	dispatch_queue_t background = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND,0);
	dispatch_async(background, ^{
		[data writeToFile:cachedURL.path atomically:TRUE];
		if(writeCompletion) {
			dispatch_async(dispatch_get_main_queue(), ^{
				writeCompletion(cachedURL,data);
			});
		}
	});
}

- (void) writeCacheControlData:(UIImageCacheData *) cache toFile:(NSURL *) cachedURL {
	dispatch_queue_t background = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND,0);
	dispatch_async(background, ^{
		NSData * data = [NSKeyedArchiver archivedDataWithRootObject:cache];
		[data writeToFile:cachedURL.path atomically:TRUE];
		NSDictionary * attributes = @{NSFileModificationDate:[NSDate date]};
		[[NSFileManager defaultManager] setAttributes:attributes ofItemAtPath:cachedURL.path error:nil];
	});
}

- (void) loadImageInBackground:(NSURL *) diskURL imageURL:(NSURL *) imageURL completion:(UIImageLoadedBlock) completion {
	dispatch_queue_t background = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND,0);
	dispatch_async(background, ^{
		NSDate * modified = [NSDate date];
		NSDictionary * attributes = @{NSFileModificationDate:modified};
		[[NSFileManager defaultManager] setAttributes:attributes ofItemAtPath:diskURL.path error:nil];
		UIImage * image = [UIImage imageWithContentsOfFile:diskURL.path];
		if(self.cacheImagesInMemory) {
			[self.memoryCache cacheImage:image forURL:imageURL];
		}
		dispatch_async(dispatch_get_main_queue(), ^{
			if(completion) {
				completion(image);
			}
		});
	});
}

- (void) setCacheControlForCacheInfo:(UIImageCacheData *) cacheInfo fromCacheControlString:(NSString *) cacheControl {
	if([cacheControl isEqualToString:@"no-cache"]) {
		cacheInfo.nocache = TRUE;
		return;
	}
	
	NSScanner * scanner = [[NSScanner alloc] initWithString:cacheControl];
	NSString * prelim = nil;
	[scanner scanUpToString:@"=" intoString:&prelim];
	[scanner scanString:@"=" intoString:nil];
	
	double maxage = -1;
	[scanner scanDouble:&maxage];
	if(maxage > -1) {
		cacheInfo.maxage = (NSTimeInterval)maxage;
	}
}

- (NSURLSessionDataTask *) cacheImageWithRequestUsingCacheControl:(NSURLRequest *) request
	hasCache:(UIImageDiskCacheDiskURLCompletion) hasCache
	sendRequest:(UIImageDiskCache_SendingRequestBlock) sendRequest
	requestCompleted:(UIImageDiskCacheURLCompletion) requestCompleted {
	
	if(!request.URL) {
		NSLog(@"[UIImageDiskCache] ERROR: request.URL was NULL");
		requestCompleted([NSError errorWithDomain:UIImageDiskCacheErrorDomain code:UIImageDiskCacheErrorNilURL userInfo:@{NSLocalizedDescriptionKey:@"request.URL is nil"}],nil,UIImageLoadSourceNone);
	}
	
	//make mutable request
	NSMutableURLRequest * mutableRequest = [request mutableCopy];
	[self setAuthorization:mutableRequest];
	
	//get cache file urls
	NSURL * cacheInfoFile = [self localCacheControlFileURLForURL:request.URL];
	NSURL * cachedImageURL = [self localFileURLForURL:request.URL];
	
	//setup blank cache object
	UIImageCacheData * cached = nil;
	
	//load cached info file if it exists.
	if([[NSFileManager defaultManager] fileExistsAtPath:cacheInfoFile.path]) {
		cached = [NSKeyedUnarchiver unarchiveObjectWithFile:cacheInfoFile.path];
	} else {
		cached = [[UIImageCacheData alloc] init];
	}
	
	//check max age
	NSDate * now = [NSDate date];
	NSDate * createdDate = [self createdDateForFileURL:cachedImageURL];
	NSTimeInterval diff = [now timeIntervalSinceDate:createdDate];
	BOOL cacheValid = FALSE;
	
	//check cache expiration
	if(!cached.nocache && cached.maxage > 0 && diff < cached.maxage) {
		cacheValid = TRUE;
	}
	
	BOOL didSendCacheCompletion = FALSE;
	
	//file exists.
	if([[NSFileManager defaultManager] fileExistsAtPath:cachedImageURL.path]) {
		if(cacheValid) {
			hasCache(cachedImageURL);
			return nil;
		} else {
			didSendCacheCompletion = TRUE;
			dispatch_async(dispatch_get_main_queue(), ^{
				//call placeholder completion and continue load below
				hasCache(cachedImageURL);
			});
		}
	} else {
		if(self.logCacheMisses) {
			NSLog(@"[UIImageDiskCache] cache miss for url: %@",request.URL);
		}
	}
	
	//ignore built in cache from networking code. handled here instead.
	mutableRequest.cachePolicy = NSURLRequestReloadIgnoringCacheData;
	
	//check if there's an etag from the server available.
	if(cached.etag) {
		[mutableRequest setValue:cached.etag forHTTPHeaderField:@"If-None-Match"];
		
		if(cached.maxage == 0) {
			if(self.logResponseWarnings) {
				NSLog(@"[UIImageDiskCache] WARNING: Cached Image response ETag is set but no Cache-Control is available. "
					  @"Image requests will always be sent, the response may or may not be 304. "
					  @"Add Cache-Control policies to the server to correctly have content expire locally. "
					  @"URL: %@",mutableRequest.URL);
			}
		}
	}
	
	dispatch_async(dispatch_get_main_queue(), ^{
		sendRequest(didSendCacheCompletion);
	});
	
	__weak UIImageDiskCache * weakself = self;
	
	NSURLSessionDataTask * task = [[self session] dataTaskWithRequest:mutableRequest completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
		dispatch_async(dispatch_get_main_queue(), ^{
			if(error) {
				requestCompleted(error,nil,UIImageLoadSourceNone);
				return;
			}
			
			NSHTTPURLResponse * httpResponse = (NSHTTPURLResponse *)response;
			NSDictionary * headers = [httpResponse allHeaderFields];
			
			//304 Not Modified. Use Cache.
			if(httpResponse.statusCode == 304) {
				
				if(headers[@"Cache-Control"]) {
					NSString * control = headers[@"Cache-Control"];
					[self setCacheControlForCacheInfo:cached fromCacheControlString:control];
					[self writeCacheControlData:cached toFile:cacheInfoFile];
				}
				
				requestCompleted(nil,cachedImageURL,UIImageLoadSourceNetworkNotModified);
				return;
			}
			
			//status not OK, error.
			if(httpResponse.statusCode != 200) {
				NSString * message = [NSString stringWithFormat:@"Invalid image cache response %li",(long)httpResponse.statusCode];
				requestCompleted([NSError errorWithDomain:UIImageDiskCacheErrorDomain code:UIImageDiskCacheErrorResponseCode userInfo:@{NSLocalizedDescriptionKey:message}],nil,UIImageLoadSourceNone);
				return;
			}
			
			//check that content type is an image.
			NSString * contentType = headers[@"Content-Type"];
			if(![weakself acceptedContentType:contentType]) {
				requestCompleted([NSError errorWithDomain:UIImageDiskCacheErrorDomain code:UIImageDiskCacheErrorContentType userInfo:@{NSLocalizedDescriptionKey:@"Response was not an image"}],nil,UIImageLoadSourceNone);
				return;
			}
			
			//check response for etag and cache control
			if(!headers[@"ETag"] && !headers[@"Cache-Control"]) {
				if(self.logResponseWarnings) {
					NSLog(@"[UIImageDiskCache] WARNING: You are loading images using the server cache control but the server returned neither ETag or Cache-Control. "
						  @"Images will continue to load every time the image is needed. "
						  @"URL: %@",mutableRequest.URL);
				}
			}
			
			if(headers[@"ETag"]) {
				cached.etag = headers[@"ETag"];
				
				if(self.etagOnlyCacheControl > 0) {
					cached.maxage = self.etagOnlyCacheControl;
				}
				
				if(!headers[@"Cache-Control"] && self.etagOnlyCacheControl < 1) {
					if(self.logResponseWarnings ) {
						NSLog(@"[UIImageDiskCache] WARNING: Image response header ETag is set but no Cache-Control is available. "
							  @"You can set a custom cache control for this scenario with the etagOnlyCacheControl property. "
							  @"Image requests will always be sent, the response may or may not be 304. "
							  @"Optionally add Cache-Control policies to the server to correctly have content expire locally. "
							  @"URL: %@",mutableRequest.URL);
					}
				}
			}
			
			if(headers[@"Cache-Control"]) {
				NSString * control = headers[@"Cache-Control"];
				[self setCacheControlForCacheInfo:cached fromCacheControlString:control];
			}
			
			//save cached info file
			[weakself writeCacheControlData:cached toFile:cacheInfoFile];
			
			//save image to disk
			[weakself writeData:data toFile:cachedImageURL writeCompletion:^(NSURL *url, NSData *data) {
				requestCompleted(nil,cachedImageURL,UIImageLoadSourceNetworkToDisk);
			}];
			
		});
	}];
	
	[task resume];
	
	return task;
}

- (NSURLSessionDataTask *) cacheImageWithRequest:(NSURLRequest *) request
	hasCache:(UIImageDiskCacheDiskURLCompletion) hasCache
	sendRequest:(UIImageDiskCache_SendingRequestBlock) sendRequest
	requestComplete:(UIImageDiskCacheURLCompletion) requestComplete {
	
	//if use server cache policies, use other method.
	if(self.useServerCachePolicy) {
		return [self cacheImageWithRequestUsingCacheControl:request hasCache:hasCache sendRequest:sendRequest requestCompleted:requestComplete];
	}
	
	if(!request.URL) {
		NSLog(@"[UIImageDiskCache] ERROR: request.URL was NULL");
		requestComplete([NSError errorWithDomain:UIImageDiskCacheErrorDomain code:UIImageDiskCacheErrorNilURL userInfo:@{NSLocalizedDescriptionKey:@"request.URL is nil"}],nil,UIImageLoadSourceNone);
	}
	
	//make mutable request
	NSMutableURLRequest * mutableRequest = [request mutableCopy];
	[self setAuthorization:mutableRequest];
	
	NSURL * cachedURL = [self localFileURLForURL:mutableRequest.URL];
	if([[NSFileManager defaultManager] fileExistsAtPath:cachedURL.path]) {
		dispatch_async(dispatch_get_main_queue(), ^{
			hasCache(cachedURL);
		});
		return nil;
	}
	
	if(self.logCacheMisses) {
		NSLog(@"[UIImageDiskCache] cache miss for url: %@",mutableRequest.URL);
	}
	
	dispatch_async(dispatch_get_main_queue(), ^{
		sendRequest(FALSE);
	});
	
	__weak UIImageDiskCache * weakSelf = self;
	
	NSURLSessionDataTask * task = [[self session] dataTaskWithRequest:mutableRequest completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
		dispatch_async(dispatch_get_main_queue(), ^{
			if(error) {
				requestComplete(error,nil,UIImageLoadSourceNone);
				return;
			}
			
			NSHTTPURLResponse * httpResponse = (NSHTTPURLResponse *)response;
			if(httpResponse.statusCode != 200) {
				NSString * message = [NSString stringWithFormat:@"Invalid image cache response %li",(long)httpResponse.statusCode];
				requestComplete([NSError errorWithDomain:UIImageDiskCacheErrorDomain code:UIImageDiskCacheErrorResponseCode userInfo:@{NSLocalizedDescriptionKey:message}],nil,UIImageLoadSourceNone);
				return;
			}
			
			NSString * contentType = [[httpResponse allHeaderFields] objectForKey:@"Content-Type"];
			if(![weakSelf acceptedContentType:contentType]) {
				requestComplete([NSError errorWithDomain:UIImageDiskCacheErrorDomain code:UIImageDiskCacheErrorContentType userInfo:@{NSLocalizedDescriptionKey:@"Response was not an image"}],nil,UIImageLoadSourceNone);
				return;
			}
			
			if(data) {
				
				[weakSelf writeData:data toFile:cachedURL writeCompletion:^(NSURL *url, NSData *data) {
					requestComplete(nil,cachedURL,UIImageLoadSourceNetworkToDisk);
				}];
			}
		});
	}];
	
	[task resume];
	
	return task;
}

@end

/********************/
/* UIImageCacheData */
/********************/

@implementation UIImageCacheData

- (id) init {
	self = [super init];
	self.maxage = 0;
	self.etag = nil;
	return self;
}

- (id) initWithCoder:(NSCoder *)aDecoder {
	self = [super init];
	NSKeyedUnarchiver * un = (NSKeyedUnarchiver *)aDecoder;
	self.maxage = [un decodeDoubleForKey:@"maxage"];
	self.etag = [un decodeObjectForKey:@"etag"];
	self.nocache = [un decodeBoolForKey:@"nocache"];
	return self;
}

- (void) encodeWithCoder:(NSCoder *)aCoder {
	NSKeyedArchiver * ar = (NSKeyedArchiver *)aCoder;
	[ar encodeObject:self.etag forKey:@"etag"];
	[ar encodeDouble:self.maxage forKey:@"maxage"];
	[ar encodeBool:self.nocache forKey:@"nocache"];
}

@end

/************************/
/* UIImageView Addition */
/************************/

@implementation UIImageView (UIImageDiskCache)

- (NSURLSessionDataTask *) setImageWithRequest:(NSURLRequest *) request
	cache:(UIImageDiskCache *) cache
	hasCache:(UIImageDiskCache_HasCacheBlock) hasCache
	sendRequest:(UIImageDiskCache_SendingRequestBlock) sendRequest
	requestCompleted:(UIImageDiskCache_RequestCompletedBlock) requestCompleted; {
	
	//check memory cache
	UIImage * image = [cache.memoryCache.cache objectForKey:request.URL.path];
	if(image) {
		hasCache(image,UIImageLoadSourceMemory);
		return nil;
	}
	
	return [cache cacheImageWithRequest:request hasCache:^(NSURL *diskURL) {
		
		[cache loadImageInBackground:diskURL imageURL:request.URL completion:^(UIImage *image) {
			dispatch_async(dispatch_get_main_queue(), ^{
				hasCache(image,UIImageLoadSourceDisk);
			});
		}];
		
	} sendRequest:sendRequest requestComplete:^(NSError *error, NSURL *diskURL, UIImageLoadSource loadedFromSource) {
		
		if(loadedFromSource == UIImageLoadSourceNetworkToDisk) {
			[cache loadImageInBackground:diskURL imageURL:request.URL completion:^(UIImage *image) {
				dispatch_async(dispatch_get_main_queue(), ^{
					requestCompleted(error,image,loadedFromSource);
				});
			}];
		} else {
			requestCompleted(error,nil,loadedFromSource);
		}
		
	}];
}

- (NSURLSessionDataTask *) setImageWithURL:(NSURL *) url
									 cache:(UIImageDiskCache *) cache
								  hasCache:(UIImageDiskCache_HasCacheBlock) hasCache
							   sendRequest:(UIImageDiskCache_SendingRequestBlock) sendRequest
						  requestCompleted:(UIImageDiskCache_RequestCompletedBlock) requestCompleted; {
	NSURLRequest * request = [NSURLRequest requestWithURL:url];
	return [self setImageWithRequest:request cache:cache hasCache:hasCache sendRequest:sendRequest requestCompleted:requestCompleted];
}

- (NSURLSessionDataTask *) setImageWithURL:(NSURL *) url
								  hasCache:(UIImageDiskCache_HasCacheBlock) hasCache
							   sendRequest:(UIImageDiskCache_SendingRequestBlock) sendRequest
						  requestCompleted:(UIImageDiskCache_RequestCompletedBlock) requestCompleted; {
	return [self setImageWithURL:url cache:[UIImageDiskCache defaultDiskCache] hasCache:hasCache sendRequest:sendRequest requestCompleted:requestCompleted];
}

- (NSURLSessionDataTask *) setImageWithRequest:(NSURLRequest *) request
									  hasCache:(UIImageDiskCache_HasCacheBlock) hasCache
								   sendRequest:(UIImageDiskCache_SendingRequestBlock) sendRequest
							  requestCompleted:(UIImageDiskCache_RequestCompletedBlock) requestCompleted; {
	return [self setImageWithRequest:request cache:[UIImageDiskCache defaultDiskCache] hasCache:hasCache sendRequest:sendRequest requestCompleted:requestCompleted];
}

@end

/*********************/
/* UIButton Addition */
/*********************/


//@implementation UIButton (UIImageDiskCache)
//
//- (void) setImageInBackground:(NSURL *) cachedURL isBackgroundImage:(BOOL) isBackgroundImage controlState:(UIControlState) controlState cache:(UIImageDiskCache *) cache imageLoadSource:(UIImageLoadSource) imageLoadSource url:(NSURL *) url completion:(UIImageDiskCacheCompletion) completion {
//	__weak UIButton * weakSelf = self;
//	dispatch_queue_t background = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND,0);
//	dispatch_async(background, ^{
//		NSDate * modified = [NSDate date];
//		NSDictionary * attributes = @{NSFileModificationDate:modified};
//		[[NSFileManager defaultManager] setAttributes:attributes ofItemAtPath:cachedURL.path error:nil];
//		UIImage * image = [UIImage imageWithContentsOfFile:cachedURL.path];
//		if(cache.cacheImagesInMemory) {
//			[cache.memoryCache cacheImage:image forURL:url];
//		}
//		dispatch_async(dispatch_get_main_queue(), ^{
//			if(isBackgroundImage) {
//				[weakSelf setBackgroundImage:image forState:controlState];
//			} else {
//				[weakSelf setImage:image forState:controlState];
//			}
//			if(completion) {
//				completion(nil,image,url,imageLoadSource);
//			}
//		});
//	});
//}
//
//- (NSURLSessionDataTask *) setImageForControlState:(UIControlState) controlState withRequest:(NSURLRequest *) request customCache:(UIImageDiskCache *) customCache completion:(UIImageDiskCacheCompletion) completion; {
//	UIImage * image = [customCache.memoryCache.cache objectForKey:request.URL];
//	if(image) {
//		[self setImage:image forState:controlState];
//		completion(nil,image,request.URL,UIImageLoadSourceMemory);
//		return nil;
//	}
//	
//	return [customCache cacheImageWithRequest:request completion:^(NSError *error, NSURL *diskURL, NSURL * url, UIImageLoadSource loadSource) {
//		if(error) {
//			completion(error,nil,url,loadSource);
//			return;
//		}
//		[self setImageInBackground:diskURL isBackgroundImage:FALSE controlState:controlState cache:customCache imageLoadSource:loadSource url:url completion:completion];
//	}];
//}
//
//- (NSURLSessionDataTask *) setBackgroundImageForControlState:(UIControlState) controlState withRequest:(NSURLRequest *) request customCache:(UIImageDiskCache *) customCache completion:(UIImageDiskCacheCompletion) completion; {
//	UIImage * image = [customCache.memoryCache.cache objectForKey:request.URL];
//	if(image) {
//		[self setBackgroundImage:image forState:controlState];
//		completion(nil,image,request.URL,UIImageLoadSourceMemory);
//		return nil;
//	}
//	
//	return [customCache cacheImageWithRequest:request completion:^(NSError *error, NSURL *diskURL, NSURL * url, UIImageLoadSource loadSource) {
//		if(error) {
//			completion(error,nil,url,loadSource);
//			return;
//		}
//		[self setImageInBackground:diskURL isBackgroundImage:TRUE controlState:controlState cache:customCache imageLoadSource:loadSource url:url completion:completion];
//	}];
//}
//
//- (NSURLSessionDataTask *) setBackgroundImageForControlState:(UIControlState) controlState withURL:(NSURL *) url customCache:(UIImageDiskCache *) customCache completion:(UIImageDiskCacheCompletion) completion; {
//	NSURLRequest * request = [NSURLRequest requestWithURL:url];
//	return [self setBackgroundImageForControlState:controlState withRequest:request customCache:customCache completion:completion];
//}
//
//- (NSURLSessionDataTask *) setBackgroundImageForControlState:(UIControlState) controlState withRequest:(NSURLRequest *) request completion:(UIImageDiskCacheCompletion) completion; {
//	return [self setBackgroundImageForControlState:controlState withRequest:request customCache:[UIImageDiskCache defaultDiskCache] completion:completion];
//}
//
//- (NSURLSessionDataTask *) setBackgroundImageForControlState:(UIControlState) controlState withURL:(NSURL *) url completion:(UIImageDiskCacheCompletion) completion; {
//	NSURLRequest * request = [NSURLRequest requestWithURL:url];
//	return [self setBackgroundImageForControlState:controlState withRequest:request customCache:[UIImageDiskCache defaultDiskCache] completion:completion];
//}
//
//- (NSURLSessionDataTask *) setImageForControlState:(UIControlState) controlState withURL:(NSURL *) url customCache:(UIImageDiskCache *) customCache completion:(UIImageDiskCacheCompletion) completion; {
//	NSURLRequest * request = [NSURLRequest requestWithURL:url];
//	return [self setImageForControlState:controlState withRequest:request customCache:customCache completion:completion];
//}
//
//- (NSURLSessionDataTask *) setImageForControlState:(UIControlState) controlState withURL:(NSURL *) url completion:(UIImageDiskCacheCompletion) completion; {
//	NSURLRequest * request = [NSURLRequest requestWithURL:url];
//	return [self setBackgroundImageForControlState:controlState withRequest:request customCache:[UIImageDiskCache defaultDiskCache] completion:completion];
//}
//
//- (NSURLSessionDataTask *) setImageForControlState:(UIControlState) controlState withRequest:(NSURLRequest *) request completion:(UIImageDiskCacheCompletion) completion; {
//	return [self setImageForControlState:controlState withRequest:request customCache:[UIImageDiskCache defaultDiskCache] completion:completion];
//}
//
//@end
//
//@implementation UIImage (UIImageDiskCache)
//
//- (void) loadImageInBackground:(NSURL *) diskURL cache:(UIImageDiskCache *) cache imageLoadSource:(UIImageLoadSource) imageLoadSource url:(NSURL *) url completion:(UIImageDiskCacheCompletion) completion {
//	dispatch_queue_t background = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND,0);
//	dispatch_async(background, ^{
//		UIImage * image = [UIImage imageWithContentsOfFile:diskURL.path];
//		if(cache.cacheImagesInMemory) {
//			[cache.memoryCache cacheImage:image forURL:url];
//		}
//		dispatch_async(dispatch_get_main_queue(), ^{
//			if(completion) {
//				completion(nil,image,url,imageLoadSource);
//			}
//		});
//	});
//}
//
//- (NSURLSessionDataTask *) downloadImageWithRequest:(NSURLRequest *) request customCache:(UIImageDiskCache *) customCache completion:(UIImageDiskCacheCompletion)completion {
//	UIImage * image = [customCache.memoryCache.cache objectForKey:request.URL];
//	if(image) {
//		completion(nil,image,request.URL,UIImageLoadSourceMemory);
//		return nil;
//	}
//	
//	return [customCache cacheImageWithRequest:request completion:^(NSError *error, NSURL *diskURL, NSURL * url, UIImageLoadSource loadSource) {
//		if(error) {
//			completion(error,nil,url,loadSource);
//			return;
//		}
//		[self loadImageInBackground:diskURL cache:customCache imageLoadSource:loadSource url:url completion:completion];
//	}];
//}
//
//- (NSURLSessionDataTask *) downloadImageWithURL:(NSURL *) url customCache:(UIImageDiskCache *) customCache completion:(UIImageDiskCacheCompletion) completion; {
//	NSURLRequest * request = [NSURLRequest requestWithURL:url];
//	return [self downloadImageWithRequest:request customCache:customCache completion:completion];
//}
//
//- (NSURLSessionDataTask *) downloadImageWithURL:(NSURL *) url completion:(UIImageDiskCacheCompletion) completion; {
//	NSURLRequest * request = [NSURLRequest requestWithURL:url];
//	return [self downloadImageWithRequest:request customCache:[UIImageDiskCache defaultDiskCache] completion:completion];
//}
//
//- (NSURLSessionDataTask *) downloadImageWithRequest:(NSURLRequest *) request completion:(UIImageDiskCacheCompletion) completion; {
//	return [self downloadImageWithRequest:request customCache:[UIImageDiskCache defaultDiskCache] completion:completion];
//}
//
//@end
