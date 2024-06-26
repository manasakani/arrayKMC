//*****************
// Utility functions
//*****************

#include "utils.h"

ELEMENT update_element(std::string element_) {
   if (element_ == "d") {
        return DEFECT;
    } else if (element_ == "Od") {
        return OXYGEN_DEFECT;
    } else if (element_ == "V") {
        return VACANCY;
    } else if (element_ == "O") {
        return O_EL;
    } else if (element_ == "Hf") {
        return Hf_EL;
    } else if (element_ == "N") {
        return N_EL;
    } else if (element_ == "Ti") {
        return Ti_EL;
    } else if (element_ == "Pt") {
        return Pt_EL;
    } else {
        std::cout << "Error: Unknown element type in update_element!: " << element_ << std::endl;
        exit(1);
        return NULL_ELEMENT;
    }
}

std::string return_element(ELEMENT element_) {
   if (element_ == DEFECT) {
        return "d";
    } else if (element_ == OXYGEN_DEFECT) {
        return "Od";
    } else if (element_ == VACANCY) {
        return "V";
    } else if (element_ == O_EL) {
        return "O";
    } else if (element_ == Hf_EL) {
        return "Hf";
    } else if (element_ == N_EL) {
        return "N";
    } else if (element_ == Ti_EL) {
        return "Ti";
    } else if (element_ == Pt_EL) {
        return "Pt";
    } else {
        std::cout << "Error: Unknown element type in return_element()!: " << element_ << std::endl;
        //exit(1);
        return "";
    }
}

void Layer::init_layer(std::string type_, double E_gen_0_, double E_rec_1_, double E_diff_2_, double E_diff_3_, double start_x_, double end_x_)
{
    type = type_;
    E_gen_0 = E_gen_0_;
    E_rec_1 = E_rec_1_;
    E_diff_2 = E_diff_2_;
    E_diff_3 = E_diff_3_;
    start_x = start_x_;
    end_x = end_x_;
    init_vac_percentage = 0.0;
}

void Layer::disp_layer()
{
    print("Layer of type " << type << " from " << start_x << " to " << end_x);
}

int read_xyz(std::string filename, std::vector<ELEMENT> &elements,
             std::vector<double> &x, std::vector<double> &y, std::vector<double> &z)
{
    int N;
    std::string line, temp;
    std::ifstream xyz(filename);
    std::getline(xyz, line);
    std::istringstream iss1(line);
    iss1 >> N;
    std::getline(xyz, line);

    double x_, y_, z_;
    std::string element_;
    for (int i = 0; i < N; i++)
    {
        getline(xyz, line);
        std::istringstream iss(line);
        iss >> element_ >> x_ >> y_ >> z_;
        ELEMENT e = update_element(element_);
        elements.push_back(e);
        x.push_back(x_);
        y.push_back(y_);
        z.push_back(z_);
    }
    xyz.close();
    return N;
}

double site_dist(double pos1x, double pos1y, double pos1z, 
                 double pos2x, double pos2y, double pos2z, std::vector<double> lattice, bool pbc)
{
    double dist = 0;
    double dist_xyz[3];

    if (pbc == 1)
    {
        
        // Find shortest distance between pos1 and the periodic images of pos2 in YZ
        double dist_x = pos1x - pos2x;
        std::vector<double> distance_frac(3);

        // starts from idx1 to exclude pbc in X-direction
        distance_frac[1] = (pos1y - pos2y) / lattice[1];
        distance_frac[1] -= round(distance_frac[1]);
        distance_frac[2] = (pos1z - pos2z) / lattice[2];
        distance_frac[2] -= round(distance_frac[2]);

        std::vector<double> dist_xyz(3);
        dist_xyz[0] = dist_x;

        for (int i = 1; i < 3; ++i) {
            dist_xyz[i] = distance_frac[i] * lattice[i];
        }

        // Calculate the norm of the xyz distance:
        return sqrt(dist_xyz[0] * dist_xyz[0] + dist_xyz[1] * dist_xyz[1] + dist_xyz[2] * dist_xyz[2]);
    }
    else
    {
        // Calculate the norm of the distance:
        dist = sqrt(pow(pos2x - pos1x, 2) + pow(pos2y - pos1y, 2) + pow(pos2z - pos1z, 2));
    }

    return dist;

}

double site_dist(std::vector<double> pos1, std::vector<double> pos2, std::vector<double> lattice, bool pbc)
{

    double dist = 0;
    double dist_xyz[3];

    if (pbc == 1)
    {
        
        // Find shortest distance between pos1 and the periodic images of pos2 in YZ
        double dist_x = pos1[0] - pos2[0];
        std::vector<double> distance_frac(3);

        for (int i = 1; i < 3; ++i) { // starts from idx1 to exclude pbc in X-direction
            distance_frac[i] = (pos1[i] - pos2[i]) / lattice[i];
            distance_frac[i] -= round(distance_frac[i]);
        }

        std::vector<double> dist_xyz(3);
        dist_xyz[0] = dist_x;

        for (int i = 1; i < 3; ++i) {
            dist_xyz[i] = distance_frac[i] * lattice[i];
        }

        // Calculate the norm of the xyz distance:
        return sqrt(dist_xyz[0] * dist_xyz[0] + dist_xyz[1] * dist_xyz[1] + dist_xyz[2] * dist_xyz[2]);

    }
    else
    {
        dist = sqrt(pow(pos2[0] - pos1[0], 2) + pow(pos2[1] - pos1[1], 2) + pow(pos2[2] - pos1[2], 2));
    }

    return dist;
}

void sort_by_x(std::vector<double> &x, std::vector<double> &y, std::vector<double> &z, std::vector<ELEMENT> &elements, std::vector<double> lattice)
{

    const std::size_t size = x.size();
    std::vector<std::size_t> indices(size);
    std::iota(indices.begin(), indices.end(), 0);

    auto cmp = [&x](std::size_t i, std::size_t j)
    {
        return x[i] < x[j];
    };

    std::sort(indices.begin(), indices.end(), cmp);
    std::vector<double> x_sorted(size);
    std::vector<double> y_sorted(size);
    std::vector<double> z_sorted(size);
    std::vector<ELEMENT> elements_sorted(size);

    for (std::size_t i = 0; i < size; ++i)
    {
        const std::size_t index = indices[i];
        x_sorted[i] = x[index];
        y_sorted[i] = y[index];
        z_sorted[i] = z[index];
        elements_sorted[i] = elements[index];
    }

    x = std::move(x_sorted);
    y = std::move(y_sorted);
    z = std::move(z_sorted);
    elements = std::move(elements_sorted);
}

void sort_by_xyz(std::vector<double> &x, std::vector<double> &y, std::vector<double> &z, std::vector<ELEMENT> &elements, std::vector<double> lattice)
{
    const std::size_t size = x.size();
    std::vector<std::size_t> indices(size);
    std::iota(indices.begin(), indices.end(), 0);

    auto cmp = [&x, &y, &z](std::size_t i, std::size_t j)
    {
        if (x[i] != x[j]) {
            return x[i] < x[j];
        }
        else if (y[i] != y[j]) {
            return y[i] < y[j];
        }
        else {
            return z[i] < z[j];
        }
    };

    std::sort(indices.begin(), indices.end(), cmp);

    std::vector<double> x_sorted(size);
    std::vector<double> y_sorted(size);
    std::vector<double> z_sorted(size);
    std::vector<ELEMENT> elements_sorted(size);

    for (std::size_t i = 0; i < size; ++i)
    {
        const std::size_t index = indices[i];
        x_sorted[i] = x[index];
        y_sorted[i] = y[index];
        z_sorted[i] = z[index];
        elements_sorted[i] = elements[index];
    }

    x = std::move(x_sorted);
    y = std::move(y_sorted);
    z = std::move(z_sorted);
    elements = std::move(elements_sorted);
}

void center_coords(std::vector<double> &x, std::vector<double> &y, std::vector<double> &z, int N, bool dim[])
{
    double min_x = *min_element(x.begin(), x.end()); // x[0];
    double min_y = *min_element(y.begin(), y.end()); // y[0];
    double min_z = *min_element(z.begin(), z.end()); // z[0];

    for (int i = 0; i < N; i++)
    {
        if (dim[0])
            x[i] -= min_x;
        if (dim[1])
            y[i] -= min_y;
        if (dim[2])
            z[i] -= min_z;
    }
}

void translate_cell(std::vector<double> &x, std::vector<double> &y, std::vector<double> &z, int N, std::vector<double> lattice, std::vector<double> shifts)
{

    bool dims[3];
    dims[0] = (shifts[0] == 0.0) ? 0 : 1;
    dims[1] = (shifts[1] == 0.0) ? 0 : 1;
    dims[2] = (shifts[2] == 0.0) ? 0 : 1;

    print("Shifting unit cell by: " << dims[0] * shifts[0] << "x, " << dims[1] * shifts[1] << "y, " << dims[2] * shifts[2] << "z");
    center_coords(x, y, z, N, dims);

    double cut_x = lattice[0] * shifts[0];
    double cut_y = lattice[1] * shifts[1];
    double cut_z = lattice[2] * shifts[2];

    for (int i = 0; i < N; i++)
    {
        if (dims[0] && x[i] < cut_x)
        {
            x[i] += lattice[0];
        }
        if (dims[1] && y[i] < cut_y)
        {
            y[i] += lattice[1];
        }
        if (dims[2] && z[i] < cut_z)
        {
            z[i] += lattice[2];
        }
    }

    center_coords(x, y, z, N, dims);
}

void save_CSR_format(const double* K, int N_left_tot, int N_right_tot, int N, const std::string& filename) {

    int nnz = 0;
    for (int i = N_left_tot; i < N - N_right_tot; i++) {
        for (int j = N_left_tot; j < N - N_right_tot; j++) {
            if (K[i * N + j] != 0) {
                nnz++;
            }
        }
    }

    std::vector<double> values(nnz);
    std::vector<int> column_indices(nnz);
    std::vector<int> row_ptr(N - N_left_tot - N_right_tot + 1, 0);

    int index = 0;
    for (int i = N_left_tot; i < N - N_right_tot; i++) {
        for (int j = N_left_tot; j < N - N_right_tot; j++) {
            if (K[i * N + j] != 0) {
                values[index] = K[i * N + j];
                column_indices[index] = j - N_left_tot;
                index++;
            }
        }
        row_ptr[i - N_left_tot + 1] = index;
    }

    // Write CSR format to file
std::ofstream file(filename);
if (file.is_open()) {
    for (int i = 0; i < nnz; i++) {
        file << values[i] << " ";
    }
    file << "\n";
    for (int i = 0; i < nnz; i++) {
        file << column_indices[i] << " ";
    }
    file << "\n";
    for (int i = 0; i < N - N_left_tot - N_right_tot + 1; i++) {
        file << row_ptr[i];
        if (i < N - N_left_tot - N_right_tot) {
            file << " ";
        }
    }
    file << "\n"; // Add a new line at the end
    file.close();
    std::cout << "CSR format data written to file: " << filename << std::endl;
} else {
    std::cerr << "Unable to open the file for writing." << std::endl;
}

}

// *****************************************************************
// *** CuBLAS calls ***
// *****************************************************************

void CheckCublasError(hipblasStatus_t const& status) {

#ifdef USE_CUDA
  if (status != HIPBLAS_STATUS_SUCCESS) {
    throw std::runtime_error("cuBLAS failed with error code: " +
                             std::to_string(status));
  }
#endif
}

hipblasHandle_t CreateCublasHandle() {
#ifdef USE_CUDA
  hipblasHandle_t handle;
  CheckCublasError(hipblasCreate(&handle));
  return handle;
#endif
}

void CreateCublasHandle(hipblasHandle_t handle) {
#ifdef USE_CUDA
  CheckCublasError(hipblasCreate(&handle));
#endif
}

void gemm(hipblasHandle_t handle, char *transa, char *transb, int *m, int *n, int *k, double *alpha, double *A, int *lda, double *B, int *ldb, double *beta, double *C, int *ldc) {

#ifdef USE_CUDA
    hipblasSetPointerMode(handle, HIPBLAS_POINTER_MODE_DEVICE);

    double *gpu_A, *gpu_B, *gpu_C, *gpu_alpha, *gpu_beta;
    hipMalloc((void**)&gpu_A, ((*m) * (*k)) * sizeof(double));
    hipMalloc((void**)&gpu_B, ((*k) * (*n)) * sizeof(double));
    hipMalloc((void**)&gpu_C, ((*m) * (*n)) * sizeof(double));
    hipMalloc((void**)&gpu_alpha, sizeof(double));
    hipMalloc((void**)&gpu_beta, sizeof(double));

    hipMemcpy(gpu_A, A, ((*m) * (*k)) * sizeof(double), hipMemcpyHostToDevice);
    hipMemcpy(gpu_B, B, ((*k) * (*n)) * sizeof(double), hipMemcpyHostToDevice);
    hipMemcpy(gpu_C, C, ((*m) * (*n)) * sizeof(double), hipMemcpyHostToDevice);
    hipMemcpy(gpu_alpha, alpha, sizeof(double), hipMemcpyHostToDevice);
    hipMemcpy(gpu_beta, beta, sizeof(double), hipMemcpyHostToDevice);

    // auto handle = CreateCublasHandle(0);
    // hipblasSetPointerMode(handle, HIPBLAS_POINTER_MODE_DEVICE);

    //printf("M, N, K, alpha, beta = %d, %d, %d, %lf, %lf\n", *m, *n, *k, *alpha, *beta);
    //printf("lda, ldb, ldc = %d, %d, %d\n", *lda, *ldb, *ldc);

    // CheckCublasError(hipblasDgemm(handle, HIPBLAS_OP_N, HIPBLAS_OP_N, *m, *n, *k, gpu_alpha, A, *lda, B, *ldb, gpu_beta, C, *ldc));
    CheckCublasError(hipblasDgemv(handle, HIPBLAS_OP_T, *m, *k, gpu_alpha, gpu_A, *lda, gpu_B, 1, gpu_beta, gpu_C, 1));
    // hipblasDgemm(handle, HIPBLAS_OP_N, HIPBLAS_OP_N, *m, *n, *k, gpu_alpha, A, *k, B, *n, gpu_beta, C, *n);
    hipDeviceSynchronize();

    // CheckCublasError(hipblasDestroy(handle));

    hipMemcpy(C, gpu_C, ((*m) * (*n)) * sizeof(double), hipMemcpyDeviceToHost);

    hipFree(gpu_A);
    hipFree(gpu_B);
    hipFree(gpu_C);
    hipFree(gpu_alpha);
    hipFree(gpu_beta);

#else

    //printf("Executing GEMM on CPU ...\n");
    //dgemm_(transa, transb, m, n, k, alpha, A, lda, B, ldb, beta, C, ldc);
    int one = 1;
    dgemv_(transa, m, k, alpha, A, lda, B, &one, beta, C, &one);

#endif

}

// *****************************************************************
// *** CuSolver calls ***
// *****************************************************************

hipsolverHandle_t CreateCusolverDnHandle(int device) {
#ifdef USE_CUDA
  hipsolverHandle_t handle;
  CheckCusolverDnError(hipsolverCreate(&handle));
  return handle;
#endif
}

// void CreateCusolverDnHandle(hipsolverHandle_t handle, int device) {
// #ifdef USE_CUDA
//   if (hipSetDevice(device) != hipSuccess) {
//     throw std::runtime_error("Failed to set CUDA device.");
//   }
//   std::cout << "making handle\n";
//   CheckCusolverDnError(hipsolverCreate(&handle));
//   std::cout << "made handle\n";
// #endif
// }

void CheckCusolverDnError(hipsolverStatus_t const &status)
{
#ifdef USE_CUDA
    if (status != HIPSOLVER_STATUS_SUCCESS)
    {
        throw std::runtime_error("cuSOLVER failed with error code: " +
                                 std::to_string(status));
    }
#endif
}

// void gesv(cusolverDnHandle_t handle, int *N, int *nrhs, double *A, int *lda, int *ipiv, double *B, int *ldb, int *info) {
void gesv(int *N, int *nrhs, double *A, int *lda, int *ipiv, double *B, int *ldb, int *info) {

#ifdef USE_CUDA

    hipsolverDnHandle_t handle = CreateCusolverDnHandle(0);

    // https://github.com/NVIDIA/CUDALibrarySamples/blob/master/cuSOLVER/getrf/cusolver_getrf_example.cu
    // printf("Solving linear system on the GPU ...\n");

    // hipblasSetPointerMode(handle, HIPBLAS_POINTER_MODE_DEVICE);
    int lwork = 0;                /* size of workspace */
    double *gpu_work = nullptr;   /* device workspace for getrf */
    int *gpu_info = nullptr;      /* error info */
    double *gpu_A, *gpu_B;
    int *gpu_ipiv;

    hipMalloc((void**)&gpu_A, ((*N) * (*N)) * sizeof(double));
    hipMalloc((void**)&gpu_B, ((*N) * (*nrhs)) * sizeof(double));
    hipMalloc((void**)&gpu_ipiv, (*N) * sizeof(int));
    hipMalloc((void **)(&gpu_info), sizeof(int));

    if (*N == *lda)
    {
        hipMemcpy(gpu_A, A, ((*N) * (*N)) * sizeof(double), hipMemcpyHostToDevice);
    } else {
        hipMemcpy2D(gpu_A,   (*N) * sizeof(double),   A,   (*lda) * sizeof(double),   (*N) * sizeof(double), (*N), hipMemcpyHostToDevice);
    }

    hipMemcpy(gpu_B, B, ((*N) * (*nrhs)) * sizeof(double), hipMemcpyHostToDevice);
    hipMemcpy(gpu_ipiv, ipiv, (*N) * sizeof(int), hipMemcpyHostToDevice);

    // CheckCusolverDnError(cusolverDnDgetrf_bufferSize(handle, *N, *N, gpu_A, *lda, &lwork));
    CheckCusolverDnError(hipsolverDgetrf_bufferSize(handle, *N, *N, gpu_A, *N, &lwork));
    hipMalloc((void **)(&gpu_work), sizeof(double) * lwork);

    // Solve Ax=B through LU factorization
    // CheckCusolverDnError(cusolverDnDgetrf(handle, *N, *N, gpu_A, *lda, gpu_work, gpu_ipiv, gpu_info));
    CheckCusolverDnError(hipsolverDnDgetrf(handle, *N, *N, gpu_A, *N, gpu_work, gpu_ipiv, gpu_info));
    // hipMemcpy(&info, gpu_info, sizeof(int), hipMemcpyDeviceToHost);
    // printf("info for cusolverDnDgetrf: %i \n", info);
    hipDeviceSynchronize();

    hipMemcpy(info, gpu_info, sizeof(int), hipMemcpyDeviceToHost);
    if (*info != 0){
        std::cout << "WARNING: info for cusolverDnDgetrf: " << *info << "\n";
    }

    // CheckCusolverDnError(cusolverDnDgetrs(handle, HIPBLAS_OP_N, *N, *nrhs, gpu_A, *lda, gpu_ipiv, gpu_B, *ldb, gpu_info));
    CheckCusolverDnError(hipsolverDnDgetrs(handle, HIPSOLVER_OP_N, *N, *nrhs, gpu_A, *N, gpu_ipiv, gpu_B, *N, gpu_info));

    hipMemcpy(info, gpu_info, sizeof(int), hipMemcpyDeviceToHost);
    if (*info != 0){
        std::cout << "WARNING: info for cusolverDnDgetrs: " << *info << "\n";
    }
    hipDeviceSynchronize();

    // Result is in B
    hipMemcpy(B, gpu_B, ((*N) * (*nrhs)) * sizeof(double), hipMemcpyDeviceToHost);

    hipFree(gpu_A);
    hipFree(gpu_B);
    hipFree(gpu_ipiv);
    hipFree(gpu_work);
    hipFree(gpu_info);

#else

    // printf("Solving linear system on the CPU ...\n");
    dgesv_(N, nrhs, A, lda, ipiv, B, ldb, info);
    if (*info != 0){
        std::cout <<"WARNING: info for dgesv %i: " << *info << "\n";
    }

#endif

}
