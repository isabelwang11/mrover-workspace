#include "obs-detector.h"
#include "rover_msgs/Target.hpp"
#include "rover_msgs/TargetList.hpp"
#include <chrono>

using namespace std;
using namespace std::chrono;
#include <glm/vec4.hpp> // glm::vec4
#include <glm/glm.hpp>
#include <vector>
#include <artag_detector.hpp>

ObsDetector::ObsDetector(DataSource source, OperationMode mode, ViewerType viewerType) : source(source), mode(mode), viewerType(viewerType), record(false)
{
    setupParamaters("");
    
    //Init data stream from source
    if(source == DataSource::ZED) {
        zed.open(init_params); 
        auto camera_config = zed.getCameraInformation(cloud_res).camera_configuration;
        defParams = camera_config.calibration_parameters.left_cam;
    } else if(source == DataSource::FILESYSTEM) {
        fileReader.open("data/");
        cout << "File data dir: " << endl;
        cout << "[e.g: /home/ashwin/Documents/mrover-workspace/jetson/percep_obs_detect/data]" << endl;
        getline(cin, readDir);
    }

    //Init Viewer
    if(mode != OperationMode::SILENT && viewerType == ViewerType::GL) {
        int argc = 1;
        char *argv[1] = {(char*)"Window"};
        viewer.init(argc, argv);
        viewer.addPointCloud();
    }

};

//TODO: Make it read params from a file
void ObsDetector::setupParamaters(std::string parameterFile) {
    //Operating resolution
    cloud_res = sl::Resolution(320, 180);
    readDir = "/home/mrover/mrover-workspace/jetson/percep_obs_detect/data";

    //Zed params
    init_params.coordinate_units = sl::UNIT::MILLIMETER;
    init_params.camera_resolution = sl::RESOLUTION::VGA; 
    init_params.camera_fps = 100;
    
    //Set the viewer paramas
    defParams.fx = 79.8502;
    defParams.fy = 80.275;
    defParams.cx = 78.8623;
    defParams.cy = 43.6901;
    defParams.image_size.width = cloud_res.width;
    defParams.image_size.height = cloud_res.height;

    //Obs Detecting Algorithm Params
    passZ = new PassThrough('z', 100, 7000); //7000
    ransacPlane = new RansacPlane(make_float3(0, 1, 0), 8, 600, 80, cloud_res.area(), 80);
    voxelGrid = new VoxelGrid(10);
    ece = new EuclideanClusterExtractor(300, 30, 0, cloud_res.area(), 9); 
}
        

void ObsDetector::update() {
    GPU_Cloud pc; 

    if(source == DataSource::ZED) {

        sl::Mat frame(cloud_res, sl::MAT_TYPE::F32_C4, sl::MEM::GPU);
        zed.grab();
        zed.retrieveMeasure(frame, sl::MEASURE::XYZRGBA, sl::MEM::GPU, cloud_res); 
        getRawCloud(pc, frame);

        /* --- Reading in Config File --- */
        rapidjson::Document mRoverConfig;
        ifstream configFile;
        string configPath = getenv("MROVER_CONFIG");
        configPath += "/config_percep/config.json";
        configFile.open( configPath );
        string config = "";
        string setting;
        while( configFile >> setting ) {
            config += setting;
        }
        configFile.close();
        mRoverConfig.Parse( config.c_str() );

        lcm::LCM lcm_;
        rover_msgs::TargetList arTagsMessage;
        rover_msgs::Target* arTags = arTagsMessage.targetList;
        arTags[0].distance = mRoverConfig["ar_tag"]["default_tag_val"].GetInt();
        arTags[1].distance = mRoverConfig["ar_tag"]["default_tag_val"].GetInt();

        /* --- Camera Initializations --- */
        Camera cam(mRoverConfig);

        Mat rgb;
        Mat src = cam.image();
        Mat depth_img = cam.depth();

        /* --- AR Tag Initializations --- */
        TagDetector detector(mRoverConfig);
        pair<Tag, Tag> tagPair;

        tagPair = detector.findARTags(src, depth_img, rgb);
        detector.updateDetectedTagInfo(arTags, tagPair, depth_img, src);

        /* --- Publish LCMs --- */
        lcm_.publish("/target_list", &arTagsMessage);
        
    } else if(source == DataSource::FILESYSTEM) {

        pc = fileReader.readCloudGPU(frameNum);
    }
    update(pc);

    if(source == DataSource::FILESYSTEM) deleteCloud(pc);
} 

///home/ashwin/Documents/mrover-workspace/jetson/percep_obs_detect/data
// Call this directly with ZED GPU Memory
void ObsDetector::update(GPU_Cloud pc) {

    // Get a copy if debug is enabled
    viewer.updatePointCloud(pc);

    // Processing

    passZ->run(pc);
    
    ransacPlane->computeModel(pc);    
    
    Bins bins;
    #if VOXEL
        bins = voxelGrid->run(pc);
    #endif
    obstacles = ece->extractClusters(pc, bins);
    ng
    if(mode != OperationMode::SILENT) {
        //viewer.addPointCloud();
        //viewer.remove
        //viewer.updatePointCloud(pc);
    }

    // Recording
    if(record) record = true;

    if(framePlay) frameNum++;
    
}

void ObsDetector::populateMessage(float leftBearing, float rightBearing, float distance) {
    this->leftBearing = leftBearing;
    this->rightBearing = rightBearing;
    this->distance = distance;
    //obstacleMessage.leftBearing = leftBearing;
    //lcm_.publish("/obstacle", &obstacleMessage);
}

void ObsDetector::spinViewer() {
    // This creates bounding boxes for visualization
    // There might be a clever automatic indexing scheme to optimize this
    for(int i = 0; i < obstacles.obs.size(); i++) {
        std::vector<vec3> points = {vec3(obstacles.obs[i].minX, obstacles.obs[i].minY, obstacles.obs[i].minZ), 
                                    vec3(obstacles.obs[i].maxX, obstacles.obs[i].minY, obstacles.obs[i].minZ), 
                                    vec3(obstacles.obs[i].maxX, obstacles.obs[i].maxY, obstacles.obs[i].minZ), 
                                    vec3(obstacles.obs[i].minX, obstacles.obs[i].maxY, obstacles.obs[i].minZ),
                                    vec3(obstacles.obs[i].minX, obstacles.obs[i].minY, obstacles.obs[i].maxZ), 
                                    vec3(obstacles.obs[i].maxX, obstacles.obs[i].minY, obstacles.obs[i].maxZ), 
                                    vec3(obstacles.obs[i].maxX, obstacles.obs[i].maxY, obstacles.obs[i].maxZ), 
                                    vec3(obstacles.obs[i].minX, obstacles.obs[i].maxY, obstacles.obs[i].maxZ),};
        std::vector<vec3> colors;
        for(int q = 0; q < 8; q++) colors.push_back(vec3(0.0f, 1.0f, 0.0f));
        std::vector<int> indicies = {0, 1, 2, 2, 3, 0, 1, 2, 5, 5, 6, 2, 0, 3, 4, 3, 7, 4, 4, 5, 6, 7, 6, 5};
        Object3D obj(points, colors, indicies);
        viewer.addObject(obj, true);
    }
    
    viewer.update();
    viewer.clearEphemerals();
}

 ObsDetector::~ObsDetector() {
     delete passZ;
     delete ransacPlane;
     delete voxelGrid;
     delete ece;
 }