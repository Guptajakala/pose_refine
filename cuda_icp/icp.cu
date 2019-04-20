#include "icp.h"
#include <thrust/transform_reduce.h>
#include <thrust/functional.h>

// for matrix multi
#include "cublas_v2.h"

// refer to icpcuda, !!!!!! not used here
// just for test, results show that thrust is faster
namespace custom_trans_reduce {

#define warpSize 32

#if __CUDA_ARCH__ < 300
#define MAX_THREADS 512
#else
#define MAX_THREADS 1024
#endif

#if __CUDA_ARCH__ < 300
__inline__ __device__
float __shfl_down(float val, int offset, int width = 32)
{
    static __shared__ float shared[MAX_THREADS];
    int lane = threadIdx.x % 32;
    shared[threadIdx.x] = val;
    __syncthreads();
    val = (lane + offset < width) ? shared[threadIdx.x + offset] : 0;
    __syncthreads();
    return val;
}
#endif

template<size_t D>
__inline__  __device__ void warpReduceSum(vec<D,  float> & val)
{
    for(int offset = warpSize / 2; offset > 0; offset /= 2)
    {
        #pragma unroll
        for(int i = 0; i < D; i++)
        {
            val[i] += __shfl_down(val[i], offset);
        }
    }
}

template<size_t D>
__inline__  __device__ void blockReduceSum(vec<D,  float> & val)
{
    static __shared__ vec<D,  float> shared[32];

    int lane = threadIdx.x % warpSize;

    int wid = threadIdx.x / warpSize;

    warpReduceSum(val);

    //write reduced value to shared memory
    if(lane == 0)
    {
        shared[wid] = val;
    }
    __syncthreads();

    //ensure we only grab a value from shared memory if that warp existed
    val = (threadIdx.x < blockDim.x / warpSize) ? shared[lane] : vec<D,  float>::Zero();

    if(wid == 0)
    {
        warpReduceSum(val);
    }
}

template<size_t D>
__global__ void reduceSum(vec<D,  float> * in, vec<D,  float> * out, int N)
{
    vec<D,  float> sum = vec<D,  float>::Zero();

    for(int i = blockIdx.x * blockDim.x + threadIdx.x; i < N; i += blockDim.x * gridDim.x)
    {
        sum += in[i];
    }

    blockReduceSum(sum);

    if(threadIdx.x == 0)
    {
        out[blockIdx.x] = sum;
    }
}

template <class transT, class originT, typename transOp>
__global__ void transform_reduce_kernel(originT* pcd_ptr, size_t pcd_size,
                                        transOp trans_op, transT* out){
    int linear_tid = blockIdx.x * blockDim.x + threadIdx.x;
    if(linear_tid > pcd_size) return;

    transT sum = trans_op(pcd_ptr[linear_tid]);
    blockReduceSum(sum);
    if(threadIdx.x == 0)
    {
        out[blockIdx.x] = sum;
    }
}

// not totally same as thrust
// vec are splited to float to add, rather than add vec once
template <class transT, class originT, typename transOp>
transT transform_reduce(originT* pcd_ptr, size_t pcd_size, transOp trans_op, transT init){
    const int threadsPerBlock = 512;
    const int numBlocks = (pcd_size + threadsPerBlock - 1)/threadsPerBlock;

    thrust::device_vector<transT> block_buffer(numBlocks);
    transT* block_buffer_ptr = thrust::raw_pointer_cast(block_buffer.data());

    thrust::device_vector<transT> result_dev(1);
    transT* result_ptr = thrust::raw_pointer_cast(result_dev.data());
    thrust::host_vector<transT> result_host(1);

    transform_reduce_kernel<<<numBlocks, threadsPerBlock>>>(pcd_ptr, pcd_size, trans_op, block_buffer_ptr);
    reduceSum<<<1, MAX_THREADS>>>(block_buffer_ptr, result_ptr, numBlocks);

    result_host = result_dev;
    return result_host[0] + init;
}
}

namespace cuda_icp{

// for debug info
#define gpuErrchk(ans) { gpuAssert((ans), __FILE__, __LINE__); }
inline void gpuAssert(cudaError_t code, const char *file, int line, bool abort=true)
{
   if (code != cudaSuccess)
   {
      fprintf(stderr,"GPUassert: %s %s %d\n", cudaGetErrorString(code), file, line);
      if (abort) exit(code);
   }
}


__global__ void transform_pcd_cuda(Vec3f* model_pcd_ptr, uint32_t model_pcd_size, Mat4x4f trans){
    uint32_t i = blockIdx.x*blockDim.x + threadIdx.x;
    if(i >= model_pcd_size) return;

    Vec3f& pcd = model_pcd_ptr[i];
    float new_x = trans[0][0]*pcd.x + trans[0][1]*pcd.y + trans[0][2]*pcd.z + trans[0][3];
    float new_y = trans[1][0]*pcd.x + trans[1][1]*pcd.y + trans[1][2]*pcd.z + trans[1][3];
    float new_z = trans[2][0]*pcd.x + trans[2][1]*pcd.y + trans[2][2]*pcd.z + trans[2][3];
    pcd.x = new_x;
    pcd.y = new_y;
    pcd.z = new_z;
}


template<class Scene>
RegistrationResult ICP_Point2Plane_cuda(device_vector_holder<Vec3f> &model_pcd, Scene scene,
                                        const ICPConvergenceCriteria criteria){
    RegistrationResult result;
    RegistrationResult backup;

    thrust::host_vector<float> A_host(36, 0);
    thrust::host_vector<float> b_host(6, 0);

    const uint32_t threadsPerBlock = 256;
    const uint32_t numBlocks = (model_pcd.size() + threadsPerBlock - 1)/threadsPerBlock;

    for(uint32_t iter=0; iter<= criteria.max_iteration_; iter++){

        Vec29f Ab_tight;

        if(iter==0 && scene.use_first){
            scene.set_first();
            Ab_tight = thrust::transform_reduce(thrust::cuda::par.on(cudaStreamPerThread),
                                            model_pcd.begin_thr(), model_pcd.end_thr(),
                                                thrust__pcd2Ab__only_T<Scene>(scene),
                                            Vec29f::Zero(), thrust__plus());
        }
        else{
            scene.reset_first();
            Ab_tight = thrust::transform_reduce(thrust::cuda::par.on(cudaStreamPerThread),
                                            model_pcd.begin_thr(), model_pcd.end_thr(), thrust__pcd2Ab<Scene>(scene),
                                            Vec29f::Zero(), thrust__plus());
        }

        // method from icpcuda
//        Vec29f Ab_tight = custom_trans_reduce::transform_reduce(model_pcd.data(), model_pcd.size(),
//                                                                thrust__pcd2Ab<Scene>(scene), Vec29f::Zero());

        cudaStreamSynchronize(cudaStreamPerThread);
        backup = result;

        float& count = Ab_tight[28];
        float& total_error = Ab_tight[27];
        if(count == 0) return result;  // avoid divid 0

        result.fitness_ = float(count) / model_pcd.size();
        result.inlier_rmse_ = std::sqrt(total_error / count);

        // last extra iter, just compute fitness & mse
        if(iter == criteria.max_iteration_) return result;

        if(std::abs(result.fitness_ - backup.fitness_) < criteria.relative_fitness_ &&
           std::abs(result.inlier_rmse_ - backup.inlier_rmse_) < criteria.relative_rmse_){
            return result;
        }

        for(int i=0; i<6; i++) b_host[i] = Ab_tight[21 + i];

        int shift = 0;
        for(int y=0; y<6; y++){
            for(int x=y; x<6; x++){
                A_host[x + y*6] = Ab_tight[shift];
                A_host[y + x*6] = Ab_tight[shift];
                shift++;
            }
        }

        Mat4x4f extrinsic = eigen_slover_666(A_host.data(), b_host.data());

        transform_pcd_cuda<<<numBlocks, threadsPerBlock>>>(model_pcd.data(), model_pcd.size(), extrinsic);
        cudaStreamSynchronize(cudaStreamPerThread);

        result.transformation_ = extrinsic * result.transformation_;
    }

    // never arrive here
    return result;
}

template RegistrationResult ICP_Point2Plane_cuda(device_vector_holder<Vec3f>&, Scene_projective, const ICPConvergenceCriteria);

template RegistrationResult ICP_Point2Plane_cuda(device_vector_holder<Vec3f>&, Scene_nn, const ICPConvergenceCriteria);




template <class T>
__global__ void depth2mask(T* depth, uint32_t* mask, uint32_t width, uint32_t height, uint32_t stride){
    uint32_t x = blockIdx.x*blockDim.x + threadIdx.x;
    uint32_t y = blockIdx.y*blockDim.y + threadIdx.y;
    if(x*stride>=width) return;
    if(y*stride>=height) return;

    if(depth[x*stride + y*stride*width] > 0) mask[x + y*width] = 1;
}

template <class T>
__global__ void depth2cloud(T* depth, Vec3f* pcd, uint32_t width, uint32_t height, uint32_t* scan, Mat3x3f K,
                          uint32_t stride, uint32_t tl_x, uint32_t tl_y){
    uint32_t x = blockIdx.x*blockDim.x + threadIdx.x;
    uint32_t y = blockIdx.y*blockDim.y + threadIdx.y;
    if(x*stride>=width) return;
    if(y*stride>=height) return;
    uint32_t index_mask = x + y*width;
    uint32_t idx_depth = x*stride + y*stride*width;
    if(depth[idx_depth] <= 0) return;

    float z_pcd = depth[idx_depth]/1000.0f;
    float x_pcd = (x + tl_x - K[0][2])/K[0][0]*z_pcd;
    float y_pcd = (y + tl_y - K[1][2])/K[1][1]*z_pcd;

    pcd[scan[index_mask]] = {x_pcd, y_pcd, z_pcd};
}

template <class T>
device_vector_holder<Vec3f> depth2cloud_cuda(T *depth, uint32_t width, uint32_t height, Mat3x3f& K,
                                 uint32_t stride, uint32_t tl_x, uint32_t tl_y)
{
    thrust::device_vector<uint32_t> mask(width*height/stride/stride, 0);
    uint32_t* mask_ptr = thrust::raw_pointer_cast(mask.data());

    const dim3 threadsPerBlock(16, 16);
    dim3 numBlocks_stride((width/stride + 15)/16, (height/stride + 15)/16);
    depth2mask<<<numBlocks_stride, threadsPerBlock>>>(depth, mask_ptr, width, height, stride);

    // avoid blocking per-thread streams
    cudaStreamSynchronize(cudaStreamPerThread);
//            gpuErrchk(cudaPeekAtLastError());

    // scan to find map: depth idx --> cloud idx
    uint32_t mask_back_temp = mask.back();
    thrust::exclusive_scan(mask.begin(), mask.end(), mask.begin(), 0); // in-place scan
    uint32_t total_pcd_num = mask.back() + mask_back_temp;

    device_vector_holder<Vec3f> cloud(total_pcd_num);
    Vec3f* cloud_ptr = cloud.data();
//    gpuErrchk(cudaPeekAtLastError());

    depth2cloud<<<numBlocks_stride, threadsPerBlock>>>(depth, cloud_ptr, width, height,
                                                 mask_ptr, K, stride, tl_x, tl_y);
    cudaStreamSynchronize(cudaStreamPerThread);
//            gpuErrchk(cudaPeekAtLastError());

    return cloud;
}

template device_vector_holder<Vec3f> depth2cloud_cuda(uint16_t *depth, uint32_t width, uint32_t height, Mat3x3f& K,
                                 uint32_t stride, uint32_t tl_x, uint32_t tl_y);
template device_vector_holder<Vec3f> depth2cloud_cuda(int32_t *depth, uint32_t width, uint32_t height, Mat3x3f& K,
                                 uint32_t stride, uint32_t tl_x, uint32_t tl_y);



/// !!!!!!!!!!!!!!!!!!!!! legacy
// just for test and comparation

template<typename T>
struct thrust__squre : public thrust::unary_function<T,T>
{
  __host__ __device__ T operator()(const T &x) const
  {
    return x * x;
  }
};

template<class Scene>
__global__ void get_Ab(const Scene scene, Vec3f* model_pcd_ptr, uint32_t model_pcd_size,
                        float* A_buffer_ptr, float* b_buffer_ptr, uint32_t* valid_buffer_ptr){
    uint32_t i = blockIdx.x*blockDim.x + threadIdx.x;
    if(i >= model_pcd_size) return;

    const auto& src_pcd = model_pcd_ptr[i];

    Vec3f dst_pcd, dst_normal; bool valid;
    scene.query(src_pcd, dst_pcd, dst_normal, valid);

    if(valid){

        // dot
        b_buffer_ptr[i] = (dst_pcd - src_pcd).x * dst_normal.x +
                      (dst_pcd - src_pcd).y * dst_normal.y +
                      (dst_pcd - src_pcd).z * dst_normal.z;

        // cross
        A_buffer_ptr[i*6 + 0] = dst_normal.z*src_pcd.y - dst_normal.y*src_pcd.z;
        A_buffer_ptr[i*6 + 1] = dst_normal.x*src_pcd.z - dst_normal.z*src_pcd.x;
        A_buffer_ptr[i*6 + 2] = dst_normal.y*src_pcd.x - dst_normal.x*src_pcd.y;

        A_buffer_ptr[i*6 + 3] = dst_normal.x;
        A_buffer_ptr[i*6 + 4] = dst_normal.y;
        A_buffer_ptr[i*6 + 5] = dst_normal.z;

        valid_buffer_ptr[i] = 1;
    }else{
        b_buffer_ptr[i] = 0;

        A_buffer_ptr[i*6 + 0] = 0;
        A_buffer_ptr[i*6 + 1] = 0;
        A_buffer_ptr[i*6 + 2] = 0;
        A_buffer_ptr[i*6 + 3] = 0;
        A_buffer_ptr[i*6 + 4] = 0;
        A_buffer_ptr[i*6 + 5] = 0;

        valid_buffer_ptr[i] = 0;
    }
    // else: invalid is 0 in A & b, ATA ATb means adding 0,
    // so don't need to consider valid_buffer, just multi matrix
}

template<class Scene>
RegistrationResult ICP_Point2Plane_cuda_global_memory_version(device_vector_holder<Vec3f> &model_pcd, Scene scene,
                                        const ICPConvergenceCriteria criteria)
{
    // buffer can make pcd handling indenpendent
    // may waste memory, but make it easy to parallel
    thrust::device_vector<float> A_buffer(model_pcd.size()*6, 0);
    thrust::device_vector<float> b_buffer(model_pcd.size(), 0);
//    thrust::device_vector<float> b_squre_buffer(model_pcd.size());
    thrust::device_vector<uint32_t> valid_buffer(model_pcd.size(), 0);
    // uint8_t is enough, uint32_t for risk in reduction

    thrust::device_vector<float> A_dev(36);
    thrust::device_vector<float> b_dev(6);

    thrust::host_vector<float> A_host(36, 0);
    thrust::host_vector<float> b_host(6, 0);
    // --------------------------------------, buffer on gpu OK

    RegistrationResult result;
    RegistrationResult backup;

    // cast to pointer, ready to feed kernel
    Vec3f* model_pcd_ptr = model_pcd.data();
    float* A_buffer_ptr =  thrust::raw_pointer_cast(A_buffer.data());

    float* b_buffer_ptr =  thrust::raw_pointer_cast(b_buffer.data());
    uint32_t* valid_buffer_ptr =  thrust::raw_pointer_cast(valid_buffer.data());

    float* A_dev_ptr =  thrust::raw_pointer_cast(A_dev.data());
    float* b_dev_ptr =  thrust::raw_pointer_cast(b_dev.data());

    float* A_host_ptr = A_host.data();
    float* b_host_ptr = b_host.data();

    const uint32_t threadsPerBlock = 256;
    const uint32_t numBlocks = (model_pcd.size() + threadsPerBlock - 1)/threadsPerBlock;

    /// cublas ----------------------------------------->
//    cublasStatus_t stat;  // CUBLAS functions status
    cublasHandle_t cublas_handle;  // CUBLAS context
    /*stat = */cublasCreate(&cublas_handle);
    float alpha =1.0f;
    float beta =0.0f;

    // avoid blocking for multi-thread
    cublasSetStream_v2(cublas_handle, cudaStreamPerThread);
    /// cublas <-----------------------------------------

//#define USE_GEMM_rather_than_SYRK

#ifdef USE_GEMM_rather_than_SYRK
    thrust::device_vector<float> AT_buffer(model_pcd.size()*6, 0);
    float* AT_buffer_ptr =  thrust::raw_pointer_cast(AT_buffer.data());
#endif

    // use one extra turn
    for(uint32_t iter=0; iter<= criteria.max_iteration_; iter++){

        get_Ab<<<numBlocks, threadsPerBlock>>>(scene, model_pcd_ptr, model_pcd.size(),
                                               A_buffer_ptr, b_buffer_ptr, valid_buffer_ptr);

        // avoid block all in multi-thread case
        cudaStreamSynchronize(cudaStreamPerThread);

        uint32_t count = thrust::reduce(thrust::cuda::par.on(cudaStreamPerThread),
                                   valid_buffer.begin(), valid_buffer.end());

//        thrust::transform(thrust::cuda::par.on(cudaStreamPerThread), b_buffer.begin(),
//                          b_buffer.end(), b_squre_buffer.begin(), thrust__squre<float>());
//        float total_error = thrust::reduce(thrust::cuda::par.on(cudaStreamPerThread),
//                                           b_squre_buffer.begin(), b_squre_buffer.end());

        //don't know why, transform reduce always return 0
        // ....... should be float(0) T_T
        float total_error = thrust::transform_reduce(thrust::cuda::par.on(cudaStreamPerThread),
                                                     b_buffer.begin(), b_buffer.end(),
                                                     thrust__squre<float>(), float(0), thrust::plus<float>());
        cudaStreamSynchronize(cudaStreamPerThread);
//        gpuErrchk(cudaPeekAtLastError());

        backup = result;

        if(count == 0) return result;  // avoid divid 0

        result.fitness_ = float(count) / model_pcd.size();
        result.inlier_rmse_ = std::sqrt(total_error / count);

//        {
//            std::cout << " --- cuda --- " << iter << " --- cuda ---" << std::endl;
//            std::cout << "total error: " << total_error << std::endl;
//            std::cout << "result.fitness_: " << result.fitness_ << std::endl;
//            std::cout << "result.inlier_rmse_: " << result.inlier_rmse_ << std::endl;
//            std::cout << " --- cuda --- " << iter << " --- cuda ---" << std::endl << std::endl;
//        }

        // last extra iter, just compute fitness & mse
        if(iter == criteria.max_iteration_) return result;

        if(std::abs(result.fitness_ - backup.fitness_) < criteria.relative_fitness_ &&
           std::abs(result.inlier_rmse_ - backup.inlier_rmse_) < criteria.relative_rmse_){
            return result;
        }

        // A = A_buffer.transpose()*A_buffer;

#ifdef USE_GEMM_rather_than_SYRK
        thrust::copy(thrust::cuda::par.on(cudaStreamPerThread), A_buffer.begin(), A_buffer.end(), AT_buffer.begin());
        cudaStreamSynchronize(cudaStreamPerThread);
        /*stat = */cublasSgemm(cublas_handle, CUBLAS_OP_N, CUBLAS_OP_T, 6,  6, model_pcd.size(),
                           &alpha, A_buffer_ptr, 6,
                           AT_buffer_ptr, 6, &beta, A_dev_ptr, 6);
#else
       /* stat = */cublasSsyrk(cublas_handle, CUBLAS_FILL_MODE_LOWER, CUBLAS_OP_N,
                            6, model_pcd.size(), &alpha, A_buffer_ptr, 6, &beta, A_dev_ptr, 6);
#endif

        /*stat = */cublasGetMatrix(6, 6, sizeof(float), A_dev_ptr , 6, A_host_ptr, 6);
        cudaStreamSynchronize(cudaStreamPerThread);

#ifndef USE_GEMM_rather_than_SYRK
//        // set upper part of ATA
        for(int y=0; y<6; y++){
            for(int x=0; x<y; x++){
                A_host[x + y*6] = A_host[y + x*6];
            }
        }
#endif
//        {
//            std::cout << " -----A------- "<< std::endl;
//            for(int i=0; i<6; i++){
//                for(int j=0; j<6; j++){
//                    std::cout << A_host[j + i*6] << "  ";
//                }
//                std::cout << "\n";
//            }
//            std::cout << " ------------\n "<< std::endl;
//        }

        // b = A_buffer.transpose()*b_buffer;
        /*stat = */cublasSgemv(cublas_handle, CUBLAS_OP_N, 6, model_pcd.size(), &alpha, A_buffer_ptr,
                          6, b_buffer_ptr, 1, &beta, b_dev_ptr, 1);


        /*stat = */cublasGetVector(6, sizeof(float), b_dev_ptr, 1, b_host_ptr, 1);
        cudaStreamSynchronize(cudaStreamPerThread);

//        {
//            std::cout << " -----b------- "<< std::endl;
//            for(int j=0; j<6; j++){
//                std::cout << b_host[j] << "  ";
//            }
//                std::cout << "\n";
//            std::cout << " ------------\n "<< std::endl;
//        }

        Mat4x4f extrinsic = eigen_slover_666(A_host_ptr, b_host_ptr);

//        {
//            std::cout << "~~extrinsic~~~~" << std::endl;
//            std::cout << extrinsic;
//            std::cout << "\n~~~~~~~~~~~~~~\n" << std::endl;
//        }

        transform_pcd_cuda<<<numBlocks, threadsPerBlock>>>(model_pcd_ptr, model_pcd.size(), extrinsic);
        cudaStreamSynchronize(cudaStreamPerThread);

        result.transformation_ = extrinsic * result.transformation_;
    }

    // never arrive here
    return result;
}

template RegistrationResult ICP_Point2Plane_cuda_global_memory_version(device_vector_holder<Vec3f>&,
Scene_projective, const ICPConvergenceCriteria);

template RegistrationResult ICP_Point2Plane_cuda_global_memory_version(device_vector_holder<Vec3f>&,
Scene_nn, const ICPConvergenceCriteria);


}



