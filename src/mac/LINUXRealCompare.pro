TEMPLATE = app
LANGUAGE	= C++

TARGET = CCompare

CONFIG	+= qt warn_on release static

QT += core gui widgets concurrent sql network

HEADERS	+= *.h 
		
SOURCES	+= *.cpp
		
FORMS += *.ui 

RESOURCES += RealCompare.qrc

ICON = main.icns

INCLUDEPATH	+= qscint/src
INCLUDEPATH	+= qscint/src/Qsci
INCLUDEPATH	+= qscint/scintilla/include

DEFINES +=  QSCINTILLA_DLL

TRANSLATIONS += realcompare_zh.ts
	
win32 {
   if(contains(QMAKE_HOST.arch, x86_64)){
    CONFIG(Debug, Debug|Release){
        DESTDIR = x64/Debug
		LIBS	+= -Lx64/Debug
		LIBS += -lqmyedit_qt5d
    }else{
        DESTDIR = x64/Release
		LIBS	+= -Lx64/Release
		LIBS += -lqmyedit_qt5
    }
   }
}


unix{

if(CONFIG(Debug, Debug|Release)){
          LIBS += -Lx64/Debug -lqmyedit_qt5_debug
}else{
          LIBS += -Lx64/Release -lqmyedit_qt5
          DESTDIR = x64/Release

        QMAKE_CXXFLAGS += -fopenmp -O2
        LIBS += -lgomp -lpthread
}
        LIBS += -luchardet
}

RC_FILE += RealCompare.rc

DISTFILES += \
    RealCompare.rc
