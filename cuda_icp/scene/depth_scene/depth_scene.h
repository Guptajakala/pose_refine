#pragma once

#include "../common.h"

// just implement query func,
// no matter it's projective or NN
struct Scene_projective{
    size_t width = 640, height = 480;
    float max_dist_diff = 0.01f; // m
    float first_dist_diff = 0.4f;
    bool use_first = true;
    bool is_first = false;
    Mat3x3f K;
    Vec3f* pcd_ptr;  // pointer can unify cpu & cuda version
    Vec3f* normal_ptr;  // layout: 1d, width*height length, array of Vec3f

    void set_first(){is_first = true;}
    void reset_first(){is_first = false;}

    // buffer provided by user, this class only holds pointers,
    // becuase we will pass them to device.
    void init_Scene_projective_cpu(cv::Mat& scene_depth, Mat3x3f& scene_K,
                                   std::vector<Vec3f>& pcd_buffer, std::vector<Vec3f>& normal_buffer);

#ifdef CUDA_ON
    void init_Scene_projective_cuda(cv::Mat& scene_depth, Mat3x3f& scene_K,
                                   device_vector_holder<Vec3f>& pcd_buffer,
                                    device_vector_holder<Vec3f>& normal_buffer);
#endif

    template<typename ...Params>
    void init(Params&&...params)
    {
    #ifdef CUDA_ON
        return init_Scene_projective_cuda(std::forward<Params>(params)...);
    #else
        return init_Scene_projective_cpu(std::forward<Params>(params)...);
    #endif
    }

    __device__ __host__
    void query(const Vec3f& src_pcd, Vec3f& dst_pcd, Vec3f& dst_normal, bool& valid) const {
        Vec3i x_y_dep = pcd2dep(src_pcd, K);

        if(x_y_dep.x >= width || x_y_dep.y >= height){
            valid = false;
            return;
        }

        size_t idx = x_y_dep.x + x_y_dep.y * width;
        dst_pcd = pcd_ptr[idx];

        if(dst_pcd.z <= 0 || std__abs(src_pcd.z - dst_pcd.z) > (is_first? first_dist_diff: max_dist_diff)){
            // better to search neibor?

            valid = false;
            return;
        }else valid = true;

        dst_normal = normal_ptr[idx];
    }
};


