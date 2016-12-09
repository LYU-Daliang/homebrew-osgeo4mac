class NoQt5WebKitAlreadyRequirement < Requirement
  fatal true
  satisfy(:build_env => false) { !(Formula["qt5"].lib/"QtWebKit.framework").exist? }

  def message; <<-EOS.undent
    Qt5 formula already has QtWebKit installed (e.g. built `--with-webkit``)
  EOS
  end
end

class Qt5Webkit < Formula
  desc "QtWebit module for Qt5"
  homepage "https://download.qt.io/community_releases/5.7/5.7.0/"
  url "https://download.qt.io/community_releases/5.7/5.7.0/qtwebkit-opensource-src-5.7.0.tar.gz"
  sha256 "30672ad5b5a12ef8ac1f07408f67713f9eb2e2688df77336047984326c294f74"

  keg_only "Qt5 is keg-only"

  depends_on NoQt5WebKitAlreadyRequirement
  # depends on "pkg-config" => :build

  depends_on "qt5"
  # TODO: main qt5 formula does not use these, should we here?
  #       the .pro setup seems to opportunistically check for them,
  #       but depending upon the formulae does not help find them
  # depends on "fontconfig"
  # depends on "icu4c"
  # depends on "webp"
  # depends on "libxslt"
  # depends on "sqlite"

  depends_on :macos => :mountain_lion
  depends_on :xcode => :build

  def install
    # On Mavericks we want to target libc++, this requires a macx-clang flag.
    if ENV.compiler == :clang && MacOS.version >= :mavericks
      spec = "macx-clang"
    else
      spec = "macx-g++"
    end
    args = %W[-config release -spec #{spec}]

    mkdir "build" do
      system Formula["qt5"].bin/"qmake", "../WebKit.pro", *args
      system "make"
      ENV.j1
      # just let it install to qt5 formula prefix
      system "make", "install"
    end

    # now move installed bits back to this formula prefix
    (lib/"cmake").mkpath
    (lib/"pkgconfig").mkpath
    # (prefix/"imports").mkpath # TODO: necessary for .pri?
    (prefix/"mkspecs/modules").mkpath
    (prefix/"plugins").mkpath
    (prefix/"qml").mkpath
    libexec.mkpath

    qt5 = Formula["qt5"]
    mv Dir["#{qt5.opt_lib}/QtWebKit*.framework"], "#{lib}/"
    mv Dir["#{qt5.opt_lib}/cmake/Qt5WebKit*"], "#{lib}/cmake/"
    mv Dir["#{qt5.opt_lib}/pkgconfig/Qt5WebKit*.pc"], "#{lib}/pkgconfig/"
    mv Dir["#{qt5.opt_prefix}/mkspecs/modules/qt_lib_webkit*.pri"], "#{prefix}/mkspecs/modules/"
    mv qt5.opt_prefix/"plugins/webkit", "#{prefix}/plugins/"
    mv qt5.opt_prefix/"qml/QtWebKit", "#{prefix}/qml/"
    mv qt5.opt_libexec/"QtWebProcess", "#{libexec}/"

    # Some config scripts will only find Qt in a "Frameworks" folder
    frameworks.install_symlink Dir["#{lib}/*.framework"]

    # The pkg-config files installed suggest that headers can be found in the
    # `include` directory. Make this so by creating symlinks from `include` to
    # the Frameworks' Headers folders.
    Pathname.glob("#{lib}/*.framework/Headers") do |path|
      include.install_symlink path => path.parent.basename(".framework")
    end

    # update pkgconfig files
    Dir["#{lib}/pkgconfig/Qt5WebKit*.pc"].each do |pc|
      inreplace pc do |s|
        s.sub! /^(prefix=).*$/, "\\1#{prefix}"
      end
    end

    # update .pri files
    # TODO: unsure if QT_MODULE_IMPORT_BASE is relative to module or its imports
    Dir["#{prefix}/mkspecs/modules/qt_lib_webkit*.pri"].each do |pri|
      inreplace pri do |s|
        s.gsub! "$$QT_MODULE_LIB_BASE", opt_lib.to_s
        next if pri.end_with? "_private.pri"
        s.gsub! "$$QT_MODULE_BIN_BASE", opt_bin.to_s
        s.gsub! "$$QT_MODULE_LIBEXEC_BASE", opt_libexec.to_s
        s.gsub! "$$QT_MODULE_PLUGIN_BASE", (opt_prefix/"plugins/webkit").to_s
        # s.gsub! "$$QT_MODULE_IMPORT_BASE", (opt_prefix/"imports").to_s
        s.gsub! "$$QT_MODULE_QML_BASE", (opt_prefix/"qml").to_s
      end
    end

    # fix up linking to QtWebKit*.frameworks in qt5 prefix path
    machos = [
      lib/"QtWebKitWidgets.framework/Versions/5/QtWebKitWidgets",
      libexec/"QtWebProcess",
      prefix/"qml/QtWebKit/libqmlwebkitplugin.dylib",
      prefix/"qml/QtWebKit/experimental/libqmlwebkitexperimentalplugin.dylib",
    ]
    qt5 = Formula["qt5"]
    machos.each do |m|
      dylibs = m.dynamically_linked_libraries
      m.ensure_writable do
        dylibs.each do |d|
          next unless d.to_s =~ %r{^#{qt5.lib}/QtWebKit(Widgets)?\.framework}
          system "install_name_tool", "-change", d, d.sub(qt5.lib, opt_lib), m.to_s
        end
      end
    end
  end

  test do
    (testpath/"hello.pro").write <<-EOS.undent
      QT        += core webkitwidgets
      TARGET     = hello
      CONFIG    += console
      CONFIG    -= app_bundle
      TEMPLATE   = app
      HEADERS    = client.h
      SOURCES   += client.cpp main.cpp
      include(#{prefix}/mkspecs/modules/qt_lib_webkit.pri)
      include(#{prefix}/mkspecs/modules/qt_lib_webkitwidgets.pri)
    EOS

    (testpath/"client.h").write <<-EOS.undent
    #ifndef CLIENT_H
    #define CLIENT_H
    #include <QWebPage>
    #include <QString>

    class Client : public QObject
    {
      Q_OBJECT

    public:
      Client(const QString &url, QObject *parent = 0);

    private Q_SLOTS:
      void loadUrl();
      void output(bool ok);

    private:
      QWebPage page;
      QString url;

    };
    #endif // CLIENT_H
    EOS

    (testpath/"client.cpp").write <<-EOS.undent
    #include "client.h"
    #include <QCoreApplication>
    #include <QDebug>
    #include <QWebFrame>
    #include <QUrl>

    Client::Client(const QString &myurl, QObject *parent)
      : QObject(parent)
      , url(myurl)
    {
    }

    void Client::loadUrl()
    {
      page.mainFrame()->load(QUrl(url));
      connect(&page, SIGNAL(loadFinished(bool)), this, SLOT(output(bool)));
    }

    void Client::output(bool ok)
    {
      if (ok){
        qDebug() << "Page title: " << page.mainFrame()->title();
        QCoreApplication::exit(0);
      } else {
        qDebug() << "Error loading " << url;
        QCoreApplication::exit(1);
      }
    }
    EOS

    (testpath/"main.cpp").write <<-EOS.undent
      #include <QApplication>
      #include <QDebug>
      #include <QTimer>
      #include <QWebView>
      #include "client.h"

      int main(int argc, char *argv[])
      {
        QApplication app(argc, argv);
        Client c("http://www.example.com/", app.instance());
        qDebug() << "Running application";
        QTimer::singleShot(1000, &c, SLOT(loadUrl()));
        return app.exec();
      }
    EOS

    cd testpath do
      system Formula["qt5"].bin/"qmake", "hello.pro"
      system "make"
      assert File.exist?("client.o")
      assert File.exist?("moc_client.o")
      assert File.exist?("main.o")
      assert File.exist?("hello")
      system "./hello"
    end
  end
end
