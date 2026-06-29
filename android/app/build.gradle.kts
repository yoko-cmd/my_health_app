plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    // END: FlutterFire Configuration
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.flutter_application_1"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // Desugaring（通知機能のための古い端末対応）を有効化
        isCoreLibraryDesugaringEnabled = true
        
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }

    kotlinOptions {
        // 文字列として "1.8" を指定
        jvmTarget = "1.8"
    }

    defaultConfig {
        applicationId = "com.example.flutter_application_1"
        
        // 修正ポイント1: 通知とFirebaseのために 23 以上にする
        minSdk = flutter.minSdkVersion 
        // 修正ポイント2: flutter.targetSdkVersion (Versionをつけるのが正解)
        targetSdk = flutter.targetSdkVersion
        
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // 変換ライブラリの読み込み
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.3")
}
