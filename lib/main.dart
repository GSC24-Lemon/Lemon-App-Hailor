import 'dart:async';
import 'dart:convert';

import 'package:device_info/device_info.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:google_speech/google_speech.dart';
import 'package:lemon_app/services/api_client.dart';
import 'package:location/location.dart';
import 'package:platform_device_id/platform_device_id.dart';
import 'package:riverpod/riverpod.dart';
import 'package:rxdart/rxdart.dart';
import 'package:sound_stream/sound_stream.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:string_similarity/string_similarity.dart';
import 'models/UserData.dart';
import 'services/websocket_client.dart';
import 'models/UserLocation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const MyApp());
}

final apiClient = ApiClient(tokenProvider: () async {
  // TODO: Get the bearer token of the current user.
  return '';
});

final webSocketClient = WebsocketClient();

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mic Stream Example',
      theme: ThemeData(
        primarySwatch: Colors.red,
        visualDensity: VisualDensity.adaptivePlatformDensity,
        colorScheme:
            ColorScheme.fromSeed(seedColor: Color.fromARGB(255, 253, 253, 253)),
        scaffoldBackgroundColor: Color.fromARGB(255, 253, 253, 253),
      ),
      home: const AudioRecognize(),
    );
  }
}

class AudioRecognize extends StatefulWidget {
  const AudioRecognize({Key? key}) : super(key: key);

  @override
  State<StatefulWidget> createState() => _AudioRecognizeState();
}

class _AudioRecognizeState extends State<AudioRecognize> {
  final RecorderStream _recorder = RecorderStream();
  stt.SpeechToText _speech = stt.SpeechToText();

  bool _isListening = false;
  double _confidence = 1.0;

  bool recognizing = false;
  bool recognizeFinished = false;
  String text = '';
  StreamSubscription<List<int>>? _audioStreamSubscription;
  BehaviorSubject<List<int>>? _audioStream;

  // get deviceId
  String? deviceId;

  UserLocation? userCurrentLocation;
  var _isGettingLocation = false;

  String backendUrl = "http://192.168.4.122:8080";
  final FlutterTts fluttertts = FlutterTts();

  // shared preferences
  SharedPreferences? loginData;

  String username = "";
  String telNumber = "";

  UserData? userData;
  String finalText = "";

  Future<String?> _getDeviceId() async {
    String? result = await PlatformDeviceId.getDeviceId;
    debugPrint("result deviceId: " + result!);
    setState(() {
      deviceId = result;
    });

    return result;
  }

  @override
  void initState() {
    super.initState();

    _recorder.initialize();
    _speech = stt.SpeechToText();
    _getDeviceId()!?.then((id) {
      _startWebSocket(id!);
    });
    check_if_already_login();

    // _speech.initialize();
  }

  void check_if_already_login() async {
    loginData = await SharedPreferences.getInstance();
    bool isLogin = loginData!.getBool('login') == true ? true : false;

    if (!isLogin) {
      screenReaderSpeak(
          "hello, please introduce your name to me so you can use the Lime application features");
    } else {
      String? userName = loginData?.getString("name");
      setState(() {
        username = userName!;
      });
      screenReaderSpeak(
          "Hello $userName!, To use the help seeking feature say the following sentence: hello lemon, I need someone's help to accompany me to [location you want to go]" +
              "To use the video call assistance feature, say the following sentence: hello lemon, I need someone to guide me to [the location you want to go to]");
    }
  }

  void screenReaderSpeak(String text) async {
    await fluttertts.setLanguage("en-US");
    await fluttertts.setPitch(1.1);
    await fluttertts.speak(text);
  }

  _startWebSocket(String id) {
    // String rilDeviceId = deviceId!;
    debugPrint("deviceId: $id");

    webSocketClient.connect(
      "ws://192.168.4.122:8080/v1/ws?deviceId=$id",
      {
        'Authorization': 'Bearer ....',
      },
    );
  }

// mendapatkan lokasi user sekarang
  void _getCurrentUserLocaton() async {
    Location location = new Location();

    bool _serviceEnabled;
    PermissionStatus _permissionGranted;
    LocationData _locationData;

    _serviceEnabled = await location.serviceEnabled();
    if (!_serviceEnabled) {
      _serviceEnabled = await location.requestService();
      if (!_serviceEnabled) {
        return null;
      }
    }

    _permissionGranted = await location.hasPermission();
    if (_permissionGranted == PermissionStatus.denied) {
      _permissionGranted = await location.requestPermission();
      if (_permissionGranted != PermissionStatus.granted) {
        return null;
      }
    }

    setState(() {
      _isGettingLocation = true;
    });
    _locationData = await location.getLocation();

    setState(() {
      _isGettingLocation = false;
    });
    _sendUserGeolocation(_locationData.latitude!, _locationData.longitude!);
    return;
  }

  _sendUserGeolocation(double lat, double long) {
    // _getDeviceId();
    // debugPrint(" deviceId: $deviceId latitude and longitude: " +
    //     lat.toString() +
    //     "long : " +
    //     long.toString());
    setState(() {
      userCurrentLocation =
          UserLocation(deviceId: deviceId!, latitude: lat, longitude: long);
    });
    var payload = {
      'type': 'user_location',
      'msg_geolocation_user': userCurrentLocation!.toJson()
    };
    webSocketClient.send(jsonEncode(payload));
  }

  void streamingRecognize() async {
    _audioStream = BehaviorSubject<List<int>>();
    _audioStreamSubscription = _recorder.audioStream.listen((event) {
      _audioStream!.add(event);
    });

    await _recorder.start();

    setState(() {
      _isListening = true;
    });
    final serviceAccount = ServiceAccount.fromString((await rootBundle
        .loadString('assets/micro-scanner-402411-a937b7573580.json')));
    final speechToText = SpeechToText.viaServiceAccount(serviceAccount);
    final config = _getConfig();

    final responseStream = speechToText.streamingRecognize(
        StreamingRecognitionConfig(config: config, interimResults: true),
        _audioStream!);

    var responseText = '';

    responseStream.listen((data) {
      final currentText =
          data.results.map((e) => e.alternatives.first.transcript).join('\n');

      if (data.results.first.isFinal) {
        responseText += '\n' + currentText;
        setState(() {
          finalText = responseText;
          recognizeFinished = true;
        });
      } else {
        setState(() {
          finalText = responseText + '\n' + currentText;
          recognizeFinished = true;
        });
      }
    }, onDone: () {
      setState(() {
        _isListening = false;
      });
    });
  }

  void stopRecording() async {
    await _recorder.stop();
    await _audioStreamSubscription?.cancel();
    await _audioStream?.close();
    setState(() {
      _isListening = false;
    });

    debugPrint("finalText: " + finalText);

    // logic voice input
    String queryOneKeyWord =
        "hello lemon i need someone's help to accompany me to";
    String queryTwoKeyword = "hello lemon my name is";
    String queryThreeKeyword = "hello lemon my telephone number is";

    var arrFinalText;
    arrFinalText = finalText.split(" ");
    if (finalText.toLowerCase().contains("help") &&
        arrFinalText.length > 9 &&
        (isSameCommand(queryOneKeyWord, finalText.toLowerCase(), 10))) {
      screenReaderSpeak(
          "okay $username, I will help you find a friend to accompany you to the location you want to go");
      sendHelpRequest(finalText);
    } else if (finalText.toLowerCase().contains("my name") &&
        arrFinalText.length > 4 &&
        (isSameCommand(queryTwoKeyword, finalText.toLowerCase(), 4))) {
      registerUserName(finalText);
    } else if ((finalText.toLowerCase().contains("telephone number") ||
            finalText.toLowerCase().contains("telepon number")) &&
        arrFinalText.length > 5 &&
        (isSameCommand(queryThreeKeyword, finalText.toLowerCase(), 5))) {
      registerTelephoneNumber(finalText);
    } else {
      bool isLogin = loginData!.getBool('login') == true ? true : false;
      if (isLogin == false) {
        screenReaderSpeak(
            "Please enter the correct voice command $username!.enter your telephone number by saying the following sentence: my telephone number is [your telephone number] ");
        return;
      }
      screenReaderSpeak(
          "Please enter the correct voice command $username!, To use the help seeking feature say the following sentence: hello lemon, I need someone's help to accompany me to [location you want to go]" +
              "To use the video call assistance feature, say the following sentence: hello lemon, I need someone to guide me to [the location you want to go to]");
    }
  }

  void sendHelpRequest(String speechText) async {
    var pattern;
    if (speechText.contains("someone's")) {
      pattern = "someone's help to accompany me to";
    } else if (speechText.contains("someone")) {
      pattern = "someone help to accompany me to";
    } else {
      screenReaderSpeak(
          "Hello $username!, To use the help seeking feature say the following sentence: hello lemon, I need someone's help to accompany me to [location you want to go]" +
              "To use the video call assistance feature, say the following sentence: hello lemon, I need someone to guide me to [the location you want to go to]");
    }

    String hailorDestination = substringMatcher(speechText, pattern);

    setState(() {
      userCurrentLocation = UserLocation(
          deviceId: deviceId!,
          latitude: userCurrentLocation!.latitude,
          longitude: userCurrentLocation!.longitude,
          username: username,
          destination: hailorDestination);
    });

    await apiClient.sendSos(jsonEncode(userCurrentLocation));
    setState(() {
      finalText = "";
    });
  }

  RecognitionConfig _getConfig() => RecognitionConfig(
      encoding: AudioEncoding.LINEAR16,
      model: RecognitionModel.basic,
      enableAutomaticPunctuation: true,
      sampleRateHertz: 16000,
      languageCode: 'en-US');

  void _listen() async {
    final isAvailable = await _speech.initialize(
      onStatus: (val) => setState(() => _isListening = true),
      onError: (val) => print('onError: $val'),
    );
    setState(() => _isListening = true);

    if (isAvailable) {
      _speech.listen(
        onResult: (val) => setState(() {
          // print("hasil: " + text);
          if (val.hasConfidenceRating && val.confidence > 0) {
            _confidence = val.confidence;
          }

          setState(() {
            finalText = val.recognizedWords;
          });
          debugPrint("tes: " + finalText);
        }),
      );
    }
  }

  // register user name
  void registerUserName(String speechText) {
    String pattern = "my name is";

    String name = substringMatcher(speechText, pattern);

    loginData!.setString("name", name);
    setState(() {
      username = name;
    });
    screenReaderSpeak(
        "thank you for introducing yourself $username, now enter your telephone number by saying the following sentence: my telephone number is [your telephone number]");
    setState(() {
      finalText = "";
    });
  }

  void registerTelephoneNumber(String speechText) async {
    var telephone;
    if (speechText.contains("telephone")) {
      String pattern = "my telephone number is";
      telephone = substringMatcher(speechText, pattern);
    } else if (speechText.contains("telepon")) {
      String pattern = "my telepon number is";
      telephone = substringMatcher(speechText, pattern);
    }

    loginData!.setString("telephone", telephone);
    setState(() {
      telNumber = telephone;
    });
    screenReaderSpeak(
        "thank you $username , now you can use the lime application, To use the help seeking feature say the following sentence: hello lemon, I need someone's help to accompany me to [location you want to go]" +
            "To use the video call assistance feature, say the following sentence: hello lemon, I need someone to guide me to [the location you want to go to]");

    setState(() {
      userData = UserData(
          username: username, telephone: telephone, deviceId: deviceId!);
      finalText = "";
    });
    loginData!.setBool("login", true);
    await apiClient.registerUser(jsonEncode(userData));
  }

  List computeLPS(String pattern) {
    List lps = List.filled(pattern.length, null);
    lps[0] = 0;
    int m = pattern.length;
    int j = 0;
    int i = 1;
    int len = 0;

    while (i < m) {
      if (pattern[i] == pattern[len]) {
        len++;
        lps[i] = len;
        i++;
      } else {
        if (len != 0) {
          len = lps[len - 1];
        } else {
          lps[i] = 0;
          i++;
        }
      }
    }

    return lps;
  }

  List<int> kmp(String text, String pattern) {
    List<int> foundIndexes = <int>[];
    int n = text.length;
    int m = pattern.length;

    int i = 0;
    int j = 0;
    List lps = computeLPS(pattern);

    while ((n - i) >= (m - j)) {
      if (pattern[j] == text[i]) {
        i++;
        j++;
      }
      if (j == m) {
        foundIndexes.add(i - j);
        j = lps[j - 1];
      } else if (i < n && pattern[j] != text[i]) {
        if (j != 0) {
          j = lps[j - 1];
        } else {
          i = i + 1;
        }
      }
    }

    return foundIndexes;
  }

  String substringMatcher(String s, String pattern) {
    s = s.toLowerCase();

    List<int> kmpRes = kmp(s, pattern);
    int i = kmpRes[0];
    int j = 0;
    while (j < pattern.length && s[i] == pattern[j]) {
      i++;
      j++;
    }

    return s.substring(i + 1);
  }

  void stopListening() {
    _speech.stop();
    setState(() => _isListening = _speech.isListening);

    // logic voice input
    String queryOneKeyWord =
        "hello lemon i need someone's help to accompany me to";
    String queryTwoKeyword = "hello lemon my name is";
    String queryThreeKeyword = "hello lemon my telephone number is";

    var arrFinalText;
    arrFinalText = finalText.split(" ");
    if (finalText.toLowerCase().contains("help") &&
        arrFinalText.length > 9 &&
        (isSameCommand(queryOneKeyWord, finalText.toLowerCase(), 10))) {
      screenReaderSpeak(
          "okay $username, I will help you find a friend to accompany you to the location you want to go");
      sendHelpRequest(finalText);
    } else if (finalText.toLowerCase().contains("my name") &&
        arrFinalText.length > 4 &&
        (isSameCommand(queryTwoKeyword, finalText.toLowerCase(), 4))) {
      registerUserName(finalText);
    } else if ((finalText.toLowerCase().contains("telephone number") ||
            finalText.toLowerCase().contains("telepon number")) &&
        arrFinalText.length > 5 &&
        (isSameCommand(queryThreeKeyword, finalText.toLowerCase(), 5))) {
      registerTelephoneNumber(finalText);
    } else {
      bool isLogin = loginData!.getBool('login') == true ? true : false;
      if (isLogin == false) {
        screenReaderSpeak(
            "Please enter the correct voice command $username!.enter your telephone number by saying the following sentence: my telephone number is [your telephone number] ");
        return;
      }
      screenReaderSpeak(
          "Please enter the correct voice command $username!, To use the help seeking feature say the following sentence: hello lemon, I need someone's help to accompany me to [location you want to go]" +
              "To use the video call assistance feature, say the following sentence: hello lemon, I need someone to guide me to [the location you want to go to]");
    }
  }

  double similiarityString(String s1, s2) {
    return s1.similarityTo(s2);
  }

  bool isSameCommand(String s1, s2, int n) {
    double tes = isSimiliar(s1, s2, n);
    String s2Benar = transformToTheRightSpechText(s1, s2, n);
    setState(() {
      finalText = s2Benar;
    });
    debugPrint("finalTextBenar: " + s2Benar);
    return tes >= 0.7;
  }

  double isSimiliar(String s1, s2, int n) {
    // n jumlah kata sampai sebelum query
    var arrS1 = s1.split(" ");
    String s1pattern = "";
    for (int i = 0; i < n; i++) {
      s1pattern += arrS1[i] + " ";
    }

    var arrS2 = s2.split(" ");
    String s2pattern = "";
    String newS2 = "";
    int i = 0;
    while (i < n) {
      s2pattern += arrS2[i] + " ";
      newS2 += arrS1[i] + " ";
      i++;
    }
    while (i < arrS2.length) {
      newS2 += arrS2[i] + " ";
      i++;
    }

    double tes = similiarityString(s1pattern, s2pattern);

    return tes;
  }

  String transformToTheRightSpechText(String s1, s2, int n) {
    // s2 yang ingin diubah ke string awaalan s1
    // n jumlah kata yang sama
    var arrS1 = s1.split(" ");
    String s1pattern = "";
    for (int i = 0; i < n; i++) {
      s1pattern += arrS1[i] + " ";
    }
    // debugPrint("s1: " + s1pattern);

    var arrS2 = s2.split(" ");
    String s2pattern = "";
    String newS2 = "";
    int i = 0;
    while (i < n) {
      s2pattern += arrS2[i] + " ";
      newS2 += arrS1[i] + " ";
      i++;
    }
    while (i < arrS2.length) {
      newS2 += arrS2[i] + " ";
      i++;
    }

    // debugPrint(" s2: " + s2pattern);
    double tes = similiarityString(s1pattern, s2pattern);

    return newS2;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              height: 100,
            ),
            Center(
              child: Image.asset('assets/images/logo.png'),
            ),
            StreamBuilder(
              stream: Stream.periodic(Duration(seconds: 2))
                  .asyncMap((i) => _getCurrentUserLocaton()),
              builder: (context, snapshot) => Container(
                width: 1.0,
                height: 0.0,
              ),
            ),
            SizedBox(
              height: 10,
            ),
            Stack(alignment: Alignment.center, children: <Widget>[
              Container(
                width: double.infinity,
                height: 480,
                color: Color.fromARGB(255, 253, 253, 253),
              ),
              Positioned(
                top: 300,
                child: Align(
                  alignment: Alignment.center,
                  child: ClipPath(
                    clipper: CustomClipPath(),
                    child: Container(
                      alignment: Alignment.center,
                      color: Color.fromARGB(255, 209, 221, 231),
                      height: 300,
                      width: 380,
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 100,
                child: ElevatedButton(
                  onPressed: !_isListening
                      ? _listen
                      : stopListening, //_listen : stopListening,
                  child: Container(
                    width: 300.0,
                    height: 300.0,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.white,
                        width: 10.0,
                      ),
                    ),
                    child: !_isListening
                        ? Icon(Icons.mic, color: Colors.white, size: 90)
                        : Icon(
                            Icons.pause,
                            color: Colors.white,
                            size: 90,
                          ),
                  ),
                  style: ButtonStyle(
                      backgroundColor: MaterialStateProperty.all(
                          Color.fromARGB(255, 250, 208, 44)),
                      shape: MaterialStateProperty.all(CircleBorder()),
                      fixedSize: MaterialStateProperty.all(Size(300, 300)),
                      padding: MaterialStateProperty.all(EdgeInsets.all(50.0)),
                      shadowColor: MaterialStateProperty.all(Colors.black)),
                ),
              ),
            ])
          ],
        ),
      ), // This trailing comma makes auto-formatting nicer for build methods.
    );
  }
}

class CustomClipPath extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    double w = size.width;
    double h = size.height;

    // final path = Path();

    Path path_0 = Path();
    path_0.moveTo(size.width * 0.0083417, size.height * 0.1425571);
    path_0.quadraticBezierTo(size.width * -0.0016000, size.height * 0.1793714,
        size.width * -0.0000500, size.height * 0.6475429);
    path_0.lineTo(size.width * 1.0005750, size.height * 0.6452143);
    path_0.quadraticBezierTo(size.width * 1.0095750, size.height * 0.1771143,
        size.width * 0.9840917, size.height * 0.1450571);
    path_0.cubicTo(
        size.width * 0.9354750,
        size.height * 0.1441857,
        size.width * 0.4975083,
        size.height * 0.3225429,
        size.width * 0.4741667,
        size.height * 0.2856000);
    path_0.cubicTo(
        size.width * 0.4431583,
        size.height * 0.3162286,
        size.width * 0.0369917,
        size.height * 0.1120143,
        size.width * 0.0083417,
        size.height * 0.1425571);
    path_0.close();
    // path.quadraticBezierTo(w * 0.5, h - 100, w, h);
    // path.close();
    return path_0;
  }

  @override
  bool shouldReclip(CustomClipper<Path> oldClipper) {
    return false;
  }
}

// class _RecognizeContent extends StatelessWidget {
//   final String? text;

//   const _RecognizeContent({Key? key, this.text}) : super(key: key);

//   @override
//   Widget build(BuildContext context) {
//     return Padding(
//       padding: const EdgeInsets.all(16.0),
//       child: Column(
//         children: <Widget>[
//           const Text(
//             'The text recognized by the Google Speech Api:',
//           ),
//           const SizedBox(
//             height: 16.0,
//           ),
//           Text(
//             text ?? '---',
//             style: Theme.of(context).textTheme.bodyText1,
//           ),
//         ],
//       ),
//     );
//   }
// }
