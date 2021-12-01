#include "obs-detector.h"

int main() {
    ObsDetector obs(DataSource::FILESYSTEM, OperationMode::DEBUG, ViewerType::GL);

    //std::thread updateTick( [&]{while(true) { obs.update();} });

    while(true) {
       obs.update();
       obs.spinViewer();
    }
    
    return 0;
}