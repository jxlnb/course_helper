import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:io' show HttpClient, Platform;
import 'package:flutter_baidu_mapapi_map/flutter_baidu_mapapi_map.dart';
import 'package:flutter_baidu_mapapi_base/flutter_baidu_mapapi_base.dart';
import 'package:flutter_baidu_mapapi_search/flutter_baidu_mapapi_search.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_bmflocation/flutter_bmflocation.dart';

/// iOS 端百度地图 SDK 与百度定位 SDK 必须在运行时通过接口设置 AK，
/// 两个插件都不会去读 Info.plist。Android 端仍然在
/// android/app/src/main/AndroidManifest.xml 的 com.baidu.lbsapi.API_KEY 中配置，
/// 因此下面的调用只在 iOS 上执行，Android 行为完全不变。
///
/// 该 AK 绑定 Bundle ID（com.jxlnb.coursehelper），换 Bundle ID 需在
/// 百度地图开放平台同步修改安全码，否则地图无瓦片、定位不出结果。
const String _baiduMapAk = 'BwImLMKeRsSOFVAVyS8UFAgzltg8lweT';

class BaiduMapWidget extends StatefulWidget {
  final Function(BMFCoordinate)? onLocationSelected;
  final Function(BMFCoordinate, String)? onLocationSelectedWithAddress;
  final bool showLocationButton;
  final bool showCurrentLocationInfo;

  const BaiduMapWidget({
    super.key,
    this.onLocationSelected,
    this.onLocationSelectedWithAddress,
    this.showLocationButton = true,
    this.showCurrentLocationInfo = true,
  });

  @override
  State<BaiduMapWidget> createState() => _BaiduMapWidgetState();
}

class _BaiduMapWidgetState extends State<BaiduMapWidget> {
  BMFMapController? _mapController;
  BMFCoordinate? _currentPosition;
  BMFCoordinate? _markerPosition;
  String _locationInfo = '正在获取位置...';
  bool _isLoading = true;
  bool _isDisposed = false;
  bool _isLocating = false;

  /// 是否已经移动过地图
  bool _hasMovedToLocation = false;

  /// 是否为用户主动触发
  bool _isManualRelocate = false;

  /// 本次定位请求是否已收到首次回调结果
  /// Android 端 singleLocation 底层复用连续定位回调
  bool _hasReceivedFirstFix = false;

  /// 百度定位 SDK 直接返回的地址文案（isReGeocode 生效时非空）。
  /// 逆地理编码搜索失败或被超时截断时用它兜底，避免显示「未知位置」。
  String _lastSdkAddress = '';

  /// 百度定位鉴权状态。这里单独存一份并常驻显示，
  /// 因为定位过程中 _locationInfo 会被反复覆盖，鉴权结果容易被冲掉。
  String _diagAuth = '鉴权：未开始';

  /// 网络自检结果：直接测百度 API 域名是否可达，
  /// 用来区分「网络/DNS 问题」和「AK 服务端问题」。
  String _diagNet = '网络自检：未运行';

  final LocationFlutterPlugin _locationPlugin = LocationFlutterPlugin();

  @override
  void initState() {
    super.initState();
    BMFMapSDK.setAgreePrivacy(true);
    _initLocation();
  }

  /// 初始化定位
  Future<void> _initLocation() async {
    // 鉴权与权限申请并行：权限弹框不必等鉴权，但真正发起定位前必须等鉴权完成，
    // 否则会出现偶发的「错误码 7：鉴权失败导致无法返回定位、地址等信息」。
    final authFuture = _initSdkApiKey();
    _runNetworkSelfTest();

    final hasPermission = await _checkPermissions();
    if (_isDisposed) return;

    if (!hasPermission) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    await authFuture;
    if (_isDisposed) return;

    await _initBaiduLocation();
    if (_isDisposed) return;

    await _getCurrentLocation(manual: false);
    if (_isDisposed) return;

    if (mounted) {
      setState(() => _isLoading = false);
    }
  }

  /// 仅 iOS：给百度定位 SDK 与百度地图 SDK 设置 AK。
  /// Android 端 AK 在 AndroidManifest.xml 中，已由原生读取，这里直接跳过。
  Future<void> _initSdkApiKey() async {
    if (!Platform.isIOS) return;

    try {
      // 定位插件的隐私合规必须单独设置：未同意之前百度定位 SDK 会拒绝工作并
      // 返回鉴权网络错误(BMKLocationAuthErrorNetworkFailed = 1)。
      // 地图插件的那句 BMFMapSDK.setAgreePrivacy 不会覆盖到定位插件。
      await _locationPlugin.setAgreePrivacy(true);

      // authAK() 会立即返回，真正的鉴权结果是通过回调异步送达的。
      // 鉴权是联网校验（请求 loc.map.baidu.com），偶发网络错误很常见，
      // 所以失败后重试几次，而不是一次失败就永久放弃。
      var authResult = 'PermissionState:timeout';
      for (var attempt = 1; attempt <= 3; attempt++) {
        final authDone = Completer<String>();
        if (mounted) {
          setState(() => _diagAuth = attempt == 1
              ? '鉴权：进行中…'
              : '鉴权：第 ${attempt - 1} 次失败，重试中…');
        }

        _locationPlugin.getApiKeyCallback(callback: (String result) {
          debugPrint('百度定位鉴权结果（第 $attempt 次）：$result');
          if (!authDone.isCompleted) authDone.complete(result);
        });

        await _locationPlugin.authAK(_baiduMapAk);
        BMFMapSDK.setApiKeyAndCoordType(_baiduMapAk, BMF_COORD_TYPE.BD09LL);

        authResult = await authDone.future.timeout(
          const Duration(seconds: 10),
          onTimeout: () => 'PermissionState:timeout',
        );
        if (_isDisposed) return;

        if (authResult.endsWith('PermissionState:0')) break;
        if (attempt < 3) {
          await Future.delayed(const Duration(seconds: 2));
          if (_isDisposed) return;
        }
      }

      // BMKLocationAuthErrorCode: 0=成功 1=网络错误 2=授权失败(AK/安全码)
      if (authResult.endsWith('PermissionState:0')) {
        if (mounted) setState(() => _diagAuth = '鉴权：✅ 成功');
      } else {
        final reason = authResult.endsWith('timeout')
            ? '等回调超时（3 次重试均失败）'
            : (authResult.endsWith('1')
                ? '网络错误(到百度鉴权服务器不通，已重试 3 次)'
                : '授权失败(AK 或安全码不匹配 / 服务未开通)');
        if (mounted) {
          setState(() => _diagAuth = '鉴权：❌ $authResult — $reason');
        }
        if (mounted) {
          setState(() => _locationInfo = '百度定位鉴权异常（$reason）');
        }
      }
    } catch (e) {
      debugPrint('设置百度 AK 失败：$e');
      if (mounted) setState(() => _diagAuth = '鉴权：❌ 异常 $e');
    }
  }

  /// 直接对百度 API 域名做一次 HTTP 探测。
  /// 地图瓦片走 CDN 域名，而定位鉴权 / 逆地理编码走 Web 服务域名，
  /// 两者的网络路径可能不同（DNS 污染、代理绕路等），
  /// 用这个结果区分「网络问题」和「AK 服务端问题」。
  Future<void> _runNetworkSelfTest() async {
    const targets = <String>[
      'https://api.map.baidu.com/',
      'https://loc.map.baidu.com/',
    ];
    final results = <String>[];

    for (final url in targets) {
      final host = Uri.parse(url).host;
      final sw = Stopwatch()..start();
      HttpClient? client;
      try {
        client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
        final req = await client.getUrl(Uri.parse(url));
        final resp = await req.close().timeout(const Duration(seconds: 8));
        await resp.forEach((_) {}); // 排空响应体，避免连接未释放
        results.add('$host → HTTP ${resp.statusCode} (${sw.elapsedMilliseconds}ms)');
      } catch (e) {
        results.add('$host → ❌失败(${sw.elapsedMilliseconds}ms): $e');
      } finally {
        client?.close(force: true);
      }
    }

    if (!mounted || _isDisposed) return;
    setState(() => _diagNet = '网络自检：${results.join('  |  ')}');
  }

  Future<void> _initBaiduLocation() async {
    _locationPlugin.singleLocationCallback(callback: (BaiduLocation result) {
      if (_isDisposed) return;

      if (_isValidFix(result)) {
        final coord = BMFCoordinate(result.latitude!, result.longitude!);
        _handleLocationUpdate(coord, result);
      } else {
        if (mounted) {
          setState(() {
            final code = result.errorCode;
            _locationInfo = code == null
                ? '定位失败，请重试'
                : '定位失败（错误码 $code：${result.errorInfo ?? '未知原因'}）';
            _isLocating = false;
            _isManualRelocate = false;
          });
        }
      }
    });

    await _prepareHighAccuracyLocation();
  }

  /// 判断一次定位回调是否携带可用坐标。
  ///
  /// Android 用 locType(>0 为成功) 标识结果类型；而 iOS 原生只下发
  /// errorCode / errorInfo 与经纬度，**从不发送 locType**，所以 iOS 上
  /// result.locType 恒为 null。若沿用 locType 判断，iOS 会把已经成功的
  /// 定位结果也当成失败丢弃，表现为「定位失败，请重试」。
  /// 因此这里以「经纬度存在 + 无错误码」为准，两端都适用。
  bool _isValidFix(BaiduLocation result) {
    if (result.latitude == null || result.longitude == null) return false;
    final code = result.errorCode;
    return code == null || code == 0;
  }

  /// 配置定位参数
  Future<void> _prepareHighAccuracyLocation() async {
    try {
      final androidOptions = BaiduLocationAndroidOption(
        coordType: BMFLocationCoordType.bd09ll,
        isNeedAddress: true,
        isNeedAltitude: false,
        isNeedLocationPoiList: false,
        isNeedNewVersionRgc: true,
        isNeedLocationDescribe: false,
        openGps: true,
        locationPurpose: BMFLocationPurpose.signIn
      );

      final iosOptions = BaiduLocationIOSOption(
        coordType: BMFLocationCoordType.bd09ll,
        locationTimeout: 15,
        reGeocodeTimeout: 15,
        desiredAccuracy: BMFDesiredAccuracy.best,
        distanceFilter: 3.0,
        // Android 侧一直有设，iOS 侧之前漏了：请求最新版逆地理编码数据
        isNeedNewVersionRgc: true,
      );

      await _locationPlugin.prepareLoc(
        androidOptions.getMap(),
        iosOptions.getMap(),
      );
    } catch (e) {
      debugPrint('配置定位参数失败：$e');
    }
  }

  /// 处理定位结果
  void _handleLocationUpdate(BMFCoordinate coordinate, BaiduLocation location) {
    if (_isDisposed || !mounted) return;

    // 忽略重复定位回调
    if (_hasReceivedFirstFix) {
      return;
    }
    _hasReceivedFirstFix = true;

    final sdkAddress = location.address?.trim() ?? '';
    if (sdkAddress.isNotEmpty) _lastSdkAddress = sdkAddress;

    setState(() {
      _currentPosition = coordinate;
      _isLocating = false;
      _locationInfo =
      '地址：${sdkAddress.isEmpty ? '解析中...' : sdkAddress}\n纬度：${coordinate.latitude.toStringAsFixed(6)}, 经度：${coordinate.longitude.toStringAsFixed(6)}';
    });

    if (_mapController != null) {
      _updateMarkerToPosition(coordinate, triggerCallback: true).then((_) {
        if (_isDisposed || !mounted) return;

        // 只在首次定位 或 用户主动重新定位时移动地图，避免"左右横跳"
        if (!_hasMovedToLocation || _isManualRelocate) {
          _moveToMarkerPosition();
          _hasMovedToLocation = true;
          _isManualRelocate = false;
        }
      });
    }
  }

  /// 发起定位
  Future<void> _getCurrentLocation({bool manual = true}) async {
    if (_isDisposed || _isLocating) return;

    setState(() {
      _isLocating = true;
      _hasReceivedFirstFix = false; // 重置单次定位守卫
      _isManualRelocate = manual; // 用户主动时才允许再次移动地图
      _locationInfo = '正在定位...';
    });

    try {
      // 避免残留
      await _locationPlugin.stopLocation();
      if (_isDisposed) return;

      await _locationPlugin.singleLocation({
        'isReGeocode': true,
        'isNetworkState': true,
      });

      Future.delayed(const Duration(seconds: 15), () {
        if (_isDisposed || !mounted) return;
        if (_isLocating) {
          setState(() {
            _isLocating = false;
            _isManualRelocate = false;
            _locationInfo = '定位超时，请重试';
          });
        }
      });
    } catch (e) {
      debugPrint('定位失败：$e');
      if (!_isDisposed && mounted) {
        setState(() {
          _locationInfo = '定位失败：$e';
          _isLocating = false;
          _isManualRelocate = false;
        });
      }
    }
  }

  /// 权限检查（保留 permission_handler 实现，可区分"永久拒绝"）
  Future<bool> _checkPermissions() async {
    var status = await Permission.location.status;

    if (status.isDenied) {
      await Permission.location.request();
      status = await Permission.location.status;
    }

    if (_isDisposed) return false;

    if (status.isPermanentlyDenied) {
      if (mounted) setState(() => _locationInfo = '定位权限被永久拒绝，请前往设置手动开启');
      return false;
    }

    return status.isGranted || PermissionStatus.limited == status;
  }

  Future<String> _updateMarkerToPosition(
      BMFCoordinate position, {
        bool triggerCallback = false,
      }) async {
    if (_isDisposed || _mapController == null) return '';

    await _mapController!.cleanAllMarkers();
    if (_isDisposed || _mapController == null) return '';

    BMFMarker marker = BMFMarker.icon(
      position: position,
      icon: 'images/placeholder.png',
      title: '当前位置',
      scaleX: 0.3,
      scaleY: 0.3
    );
    await _mapController!.addMarker(marker);
    if (_isDisposed || _mapController == null) return '';

    String address = await _getAddressFromCoordinate(position);
    if (_isDisposed || !mounted) return address;

    // 逆地理编码搜索失败/超时时，退回定位 SDK 直接给出的地址，
    // 避免把已经拿到的位置标成「未知位置」。
    if ((address.isEmpty || address == '未知位置') && _lastSdkAddress.isNotEmpty) {
      address = _lastSdkAddress;
    }

    setState(() {
      _markerPosition = position;
      _locationInfo = '地址：$address\n纬度：${position.latitude.toStringAsFixed(6)}, 经度：${position.longitude.toStringAsFixed(6)}';
    });

    if (triggerCallback) {
      _triggerCallback(position, address);
    }

    return address;
  }

  void _triggerCallback(BMFCoordinate coordinate, String address) {
    if (widget.onLocationSelectedWithAddress != null) {
      widget.onLocationSelectedWithAddress!(coordinate, address);
    } else if (widget.onLocationSelected != null) {
      widget.onLocationSelected!(coordinate);
    }
  }

  void _moveToMarkerPosition() {
    if (_isDisposed || _mapController == null || _markerPosition == null) return;
    _mapController!
        .setCenterCoordinate(_markerPosition!, true, animateDurationMs: 1000);
    _mapController!.setZoomTo(20.0, animateDurationMs: 1000);
  }

  Future<String> _getAddressFromCoordinate(BMFCoordinate coordinate) async {
    if (_isDisposed) return '未知位置';
    try {
      BMFReverseGeoCodeSearchOption option =
      BMFReverseGeoCodeSearchOption(location: coordinate);
      BMFReverseGeoCodeSearch search = BMFReverseGeoCodeSearch();
      Completer<String> completer = Completer<String>();

      search.onGetReverseGeoCodeSearchResult(
          callback: (BMFReverseGeoCodeSearchResult? result,
              BMFSearchErrorCode errorCode) {
            if (completer.isCompleted) return;
            String address = '';
            if (result != null) {
              address = result.address ?? '';
              if (address.isEmpty &&
                  result.poiList != null &&
                  result.poiList!.isNotEmpty) {
                address = result.poiList!.first.name ?? '';
              }
            }
            completer.complete(address.isNotEmpty ? address : '未知位置');
          });

      await search.reverseGeoCodeSearch(option);

      return await completer.future.timeout(
        const Duration(seconds: 6),
        onTimeout: () => '未知位置',
      );
    } catch (e) {
      return '未知位置';
    }
  }

  void _onMapTap(BMFCoordinate coordinate) async {
    if (_isDisposed || _mapController == null) return;

    await _updateMarkerToPosition(coordinate, triggerCallback: true);
    if (_isDisposed || _mapController == null) return;

    _mapController!.setCenterCoordinate(coordinate, true, animateDurationMs: 500);
    _mapController!.setZoomTo(20.0, animateDurationMs: 500);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : BMFMapWidget(
            onBMFMapCreated: (controller) {
              if (_isDisposed) return;
              _mapController = controller;

              if (_currentPosition != null) {
                _updateMarkerToPosition(_currentPosition!,
                    triggerCallback: true)
                    .then((_) {
                  if (_isDisposed || !mounted) return;
                  if (!_hasMovedToLocation) {
                    _moveToMarkerPosition();
                    _hasMovedToLocation = true;
                  }
                });
              }

              _mapController!.setMapOnClickedMapBlankCallback(
                callback: (coordinate) => _onMapTap(coordinate),
              );
            },
            mapOptions: BMFMapOptions(
              center: _currentPosition ?? BMFCoordinate(0.0, 0.0),
              zoomLevel: 20,
              mapType: BMFMapType.Standard,
            ),
          ),
        ),
        if (widget.showCurrentLocationInfo)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              boxShadow: [
                BoxShadow(
                  color: Theme.of(context).shadowColor.withValues(alpha: 0.5),
                  spreadRadius: 1,
                  blurRadius: 3,
                  offset: const Offset(0, -1),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('位置信息', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                Text(_locationInfo,
                    style: Theme.of(context).textTheme.bodyMedium),
                const SizedBox(height: 4),
                Text(_diagAuth,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.outline,
                        )),
                const SizedBox(height: 2),
                Text(_diagNet,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.outline,
                        )),
                const SizedBox(height: 12),
                Row(
                  children: [
                    ElevatedButton.icon(
                      onPressed: _isLocating ? null : () => _getCurrentLocation(manual: true),
                      icon: _isLocating
                          ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                          : const Icon(Icons.my_location, size: 18),
                      label: Text(_isLocating ? '定位中...' : '重新定位'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.primary,
                        foregroundColor: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 12),
                    if (widget.showLocationButton)
                      ElevatedButton.icon(
                        onPressed: _moveToMarkerPosition,
                        icon: const Icon(Icons.center_focus_strong, size: 18),
                        label: const Text('回到中心'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor:
                          Theme.of(context).colorScheme.secondary,
                          foregroundColor: Colors.white,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }

  @override
  void dispose() {
    _isDisposed = true;
    _locationPlugin.stopLocation();
    _mapController = null;
    super.dispose();
  }
}